#!/usr/bin/env python3
"""Run the iOS speech probe, muted, on simulators of its own; it never opens a live simulator view.

Generates the fixture and project if needed and builds the probe for the simulator once. Then
it creates one simulator per --device, boots and mutes each and runs the probe on all of them
at the same time, each under a deadline. Every simulator gets one transcript: the probe's steps
and what VoiceOver said after each. The simulators are deleted afterwards whatever happened.
It exits 0 only when every probe ran all its steps and passed, VoiceOver is off again and no
simulator lost its mute. The runner contract is in
https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover-simulator.md#runner-contract
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from types import SimpleNamespace
import simulator_voiceover_activation as activation


from _engineering import toolkit_root, project_root
toolkit_root(project_root(__file__))
from vocaro_engineering.simulators import speech as _speech
now, run, simulator_app, stop, events, staged = (_speech.now, _speech.run, _speech.simulator_app,
                                                _speech.stop, _speech.events, _speech.staged)

def state(udid, kind, *change, timeout=20):
    return _speech.state(udid, kind, *change, timeout=timeout, run_command=run)

def keep_muted(session):
    return _speech.keep_muted(session, state_reader=state)

def report(session):
    return _speech.report(session, state_reader=state, test_ended=TEST_ENDED,
                          failure_pattern=FAILURES, activation_module=activation)

DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType."
TEST = "VoiceOverProbeIOS/VoiceOverProbe/testCaptureNavigation"
STEPS = "visible,touch=Page boundary,read,activate=Next Page,visible,touch=word,read"
BUILD_REVISION_FILE = "voiceover-build-revision.txt"
# What xcodebuild prints when the probe's test has ended, and for each failure in it.
TEST_ENDED = re.compile(r"^Test Case '.*testCaptureNavigation\]' (passed|failed) \(([\d.]+) seconds\)", re.M)
FAILURES = re.compile(r"^.* error: (?:-\[.*?\] : )?(.*)$", re.M)


def build(root, derived, log_path, timeout, skip):
    """The fixture and project if they are missing or stale, then one build for every simulator."""
    products = derived / "Build/Products"
    revision_path = derived / BUILD_REVISION_FILE
    if not skip:
        # A failed or interrupted rebuild must not leave the old build's revision behind
        # (https://github.com/vocaro/vocaro-engineering/blob/main/guides/evidence.md#evidence-collection).
        revision_path.unlink(missing_ok=True)
        revision = run("git", "-C", str(root), "describe", "--always", "--dirty").strip()
        example = root / "Examples/VoiceOverVerification"
        generator = root / "scripts/make-voiceover-fixture.py"
        fixture = example / "Resources/sample.epub"
        if not fixture.exists() or fixture.stat().st_mtime < generator.stat().st_mtime:
            run(sys.executable, str(generator))
        # The generated project is ignored by Git and goes stale; the cache skips an unchanged one.
        run("xcodegen", "generate", "--use-cache", "--spec", str(example / "project.yml"), timeout=120)
        with log_path.open("w") as log:
            process = subprocess.Popen([
                "xcodebuild", "-project", str(example / "VoiceOverVerification.xcodeproj"), "-scheme", "VoiceOverProbeIOS",
                "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
                "build-for-testing"], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                if process.wait(timeout=timeout):
                    raise RuntimeError(f"The build failed; see {log_path}")
            except subprocess.TimeoutExpired:
                raise RuntimeError(f"The build did not finish in {timeout} s; see {log_path}") from None
            finally:
                stop(process)
    runs = sorted(products.glob("VoiceOverProbeIOS_*.xctestrun"), key=lambda path: path.stat().st_mtime)
    if not runs:
        raise RuntimeError(f"No built probe in {products}; run without --skip-build")
    if not skip:
        revision_path.write_text(revision + "\n")
    try:
        revision = revision_path.read_text().strip() or "unknown"
    except FileNotFoundError:
        revision = "unknown"
    return runs[-1], revision


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", action="append", metavar="TYPE",
                        help="a simulator device type, repeatable (default: iPhone-17-Pro and iPad-Air-13-inch-M4)")
    parser.add_argument("--runtime", default=os.environ.get("EPUB_SIM_RUNTIME", activation.RUNTIME),
                        help="simulator runtime (default: EPUB_SIM_RUNTIME or %(default)s)")
    parser.add_argument("--activation", choices=["stock", "cursor"],
                        help="default: guarded cursor dispatch on the pinned runtime, stock on other runtimes; stock explicitly selects an unmodified control")
    parser.add_argument("--strict", action="store_true", help="fail immediately if a requested target, rotor setting or action is missing")
    parser.add_argument("--activation-check", action="store_true", help="also require the activation canary in a stock negative control")
    parser.add_argument("--steps", default=STEPS, help="the probe's comma-separated steps (default: %(default)s)")
    parser.add_argument("--device-steps", action="append", metavar="TYPE=STEPS",
                        help="override the steps for one requested device type, repeatable")
    parser.add_argument("--font-size", help="the reader's launch text size in points")
    parser.add_argument("--flow", choices=["paginated", "scrolled"], help="the reader's launch flow (default: paginated)")
    parser.add_argument("--href", help="the section the reader opens at, as OPS/labels.xhtml (default: the book's first)")
    parser.add_argument("--book", choices=["sample", "paragraphs"], help="the bundled synthetic book (default: sample)")
    parser.add_argument("--launch", help="further launch arguments of the reader, as '-SampleSelectionLine YES'")
    parser.add_argument("--voiceover-off", action="store_true", help="leave VoiceOver off: the same steps as plain touches")
    parser.add_argument("--vot-log", action="store_true",
                        help="stream each simulator's VoiceOver log (process vot) beside its transcript")
    parser.add_argument("--timeout", type=int,
                        help="seconds each probe may take (default: 600 with cursor activation, 300 for stock)")
    parser.add_argument("--start-limit", type=int,
                        help="seconds the probe waits for VoiceOver's first phrase (default: the probe's 180)")
    parser.add_argument("--exit-grace", type=int, default=30,
                        help="seconds xcodebuild may take to end once the probe has (default: %(default)s)")
    parser.add_argument("--build-timeout", type=int, default=1200, help="seconds the build may take (default: %(default)s)")
    parser.add_argument("--skip-build", action="store_true", help="run the probe as it was last built")
    parser.add_argument("--derived-data", type=Path, default=root / ".build/voiceover/ios-simulator")
    parser.add_argument("--results", type=Path, default=root / ".build/voiceover/results")
    args = parser.parse_args()
    args.activation = args.activation or activation.default_mode(args.runtime)
    if args.timeout is None:
        args.timeout = 600 if args.activation == "cursor" and not args.voiceover_off else 300
    if args.voiceover_off and args.activation_check:
        parser.error("--activation-check requires VoiceOver; omit --voiceover-off")
    kinds = args.device or ["iPhone-17-Pro", "iPad-Air-13-inch-M4"]
    device_steps = {}
    for override in args.device_steps or []:
        kind, separator, steps = override.partition("=")
        if not separator or not steps or kind not in kinds or kind in device_steps:
            parser.error("--device-steps requires a unique requested TYPE=STEPS")
        device_steps[kind] = steps
    if not 1 <= args.timeout <= 1800:
        parser.error("--timeout must be between 1 and 1800 seconds")
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    # A terminated runner still deletes its simulators.
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda number, frame: sys.exit(128 + number))
    args.results.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    began = time.monotonic()
    window = simulator_app()
    sessions = []
    status = 0
    try:
        library = activation.prepare(root, args.derived_data, args.runtime, run) if args.activation == "cursor" and not args.voiceover_off else None
        if library:
            args.vot_log = True
        xctestrun, revision = build(root, args.derived_data, args.results / f"simulator-{stamp}.build.log",
                                    args.build_timeout, args.skip_build)
        built = time.monotonic()
        checkout = run("git", "-C", str(root), "describe", "--always", "--dirty").strip()
        xcode = " ".join(run("xcodebuild", "-version").split())
        print(f"Probe built in {built - began:.0f} s; load averages {' '.join(f'{load:.0f}' for load in os.getloadavg())}.")
        for kind in kinds:
            name = f"EPUBLib-voiceover-{kind}-{os.getpid()}"
            udid = run("xcrun", "simctl", "create", name, DEVICE_TYPE + kind, args.runtime).strip()
            sessions.append(SimpleNamespace(
                kind=kind, name=name, udid=udid, steps=device_steps.get(kind, args.steps), process=None, stream=None, started=None, ended=None, finished=None,
                note=None, late=False, recovered=[], unmuted=[], unread=[], activation=bool(library),
                log=args.results / f"simulator-{kind}-{stamp}.log", bundle=args.results / f"simulator-{kind}-{stamp}.xcresult",
                vot=args.results / f"simulator-{kind}-{stamp}.vot.log",
                transcript=[f"{now()} SIMULATOR {kind}, {args.runtime}, {udid}",
                            f"{now()} BUILD {revision}, {xcode}", f"{now()} CHECKOUT {checkout}",
                            f"{now()} SETTINGS font {args.font_size or '17'} pt, flow {args.flow or 'paginated'}, book {args.book or 'sample'}, strict {args.strict}"]))
        for session in sessions:
            run("xcrun", "simctl", "boot", session.udid, timeout=120)
        for session in sessions:
            run("xcrun", "simctl", "bootstatus", session.udid, "-b", timeout=600)
            if library:
                run("xcrun", "simctl", "spawn", session.udid, "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", str(library))
                session.transcript.append(f"{now()} ACTIVATION cursor v3, build {activation.BUILD}, vot SHA-256 {activation.VOT_SHA256}; marker and startup self-test required")
            else:
                session.transcript.append(f"{now()} ACTIVATION stock (unmodified)")
            # VoiceOver speaks through the Mac's own output device, so nothing runs before this holds
            # (https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover-simulator.md#muted-speech-capture).
            volume = state(session.udid, "audio", "--volume", "0")["volume"]
            for _ in range(5):
                if volume == 0:
                    break
                time.sleep(1)
                volume = state(session.udid, "audio", "--volume", "0")["volume"]
            if volume != 0:
                raise RuntimeError(f"{session.name} could not be muted; nothing was run")
        print(f"Simulators booted and muted in {time.monotonic() - built:.0f} s: {', '.join(session.name for session in sessions)}.")
        if args.vot_log:
            for session in sessions:
                # What VoiceOver did, where the transcript has what it read
                # (https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover-simulator.md#voiceovers-vot-log).
                session.stream = subprocess.Popen([
                    "xcrun", "simctl", "spawn", session.udid, "log", "stream", "--level", "debug", "--style", "compact",
                    "--predicate", 'process == "vot"'], stdout=session.vot.open("w"), stderr=subprocess.STDOUT,
                    start_new_session=True)
        environment = dict(os.environ, TEST_RUNNER_VOICEOVER_STEPS=args.steps)
        if library or args.activation_check:
            environment["TEST_RUNNER_VOICEOVER_ACTIVATION_CHECK"] = "1"
        if args.strict:
            environment["TEST_RUNNER_VOICEOVER_STRICT"] = "1"
        if args.font_size:
            environment["TEST_RUNNER_VOICEOVER_FONT_SIZE"] = args.font_size
        if args.flow:
            environment["TEST_RUNNER_VOICEOVER_FLOW"] = args.flow
        if args.href:
            environment["TEST_RUNNER_VOICEOVER_HREF"] = args.href
        if args.book:
            environment["TEST_RUNNER_VOICEOVER_BOOK"] = args.book
        if args.launch:
            environment["TEST_RUNNER_VOICEOVER_LAUNCH"] = args.launch
        if args.voiceover_off:
            environment["TEST_RUNNER_VOICEOVER_OFF"] = "1"
        if args.start_limit:
            environment["TEST_RUNNER_VOICEOVER_START_LIMIT"] = str(args.start_limit)
        deadline = time.monotonic() + args.timeout
        for session in sessions:
            session.transcript.append(f"{now()} STEPS {session.steps}")
            if args.href:
                session.transcript.append(f"{now()} SECTION {args.href}")
            if args.launch:
                session.transcript.append(f"{now()} LAUNCH {args.launch}")
            session.started = time.monotonic()
            # One xcodebuild per simulator. Left to collect diagnostics, it runs `simctl diagnose`
            # for up to ten minutes after a test that recorded any issue, a warning included
            # (https://github.com/vocaro/vocaro-engineering/blob/main/guides/simulator-testing.md#diagnostics-collection).
            session.process = subprocess.Popen([
                "xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                "-destination", f"platform=iOS Simulator,id={session.udid}", "-resultBundlePath", str(session.bundle),
                "-derivedDataPath", str(args.derived_data / "runs" / f"{session.kind}-{stamp}"),
                "-collect-test-diagnostics", "never", f"-only-testing:{TEST}"],
                stdout=session.log.open("w"), stderr=subprocess.STDOUT, start_new_session=True,
                env=dict(environment, TEST_RUNNER_VOICEOVER_STEPS=session.steps))
        while any(session.finished is None for session in sessions):
            time.sleep(1)
            for session in sessions:
                # Every simulator, also one whose probe has ended: VoiceOver may be on after a crash.
                keep_muted(session)
                if session.finished is not None:
                    continue
                if session.process.poll() is None:
                    if session.ended is None and TEST_ENDED.search(session.log.read_text(errors="replace")):
                        session.ended = time.monotonic()
                    if session.ended is not None and time.monotonic() - session.ended > args.exit_grace:
                        session.note = f"xcodebuild had not ended {args.exit_grace} s after the probe and was stopped"
                    elif time.monotonic() >= deadline:
                        session.note, session.late = f"the deadline of {args.timeout} s passed and xcodebuild was stopped", True
                    if session.note:
                        # Stopping it folds the staged output into the bundle: read that first
                        # (https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover-simulator.md#the-xcodebuild-diagnostics-hang).
                        session.recovered = staged(session.bundle)
                        stop(session.process)
                        # Its diagnostics collector runs in a process group of its own and outlives it.
                        subprocess.run(["pkill", "-f", f"simctl diagnose .*--udid={session.udid}"])
                if session.process.poll() is not None:
                    session.finished = time.monotonic()
    except RuntimeError as error:
        print(error)
        status = 125
    finally:
        try:
            for session in sessions:
                for process in (session.process, session.stream):
                    if process is not None:
                        stop(process)
        finally:
            for session in sessions:
                try:
                    status = max(status, report(session))
                except OSError as error:
                    print(f"{session.kind}: {error}")
                    status = max(status, 125)
            for session in sessions:
                subprocess.run(["xcrun", "simctl", "shutdown", session.udid], capture_output=True)
                deleted = subprocess.run(["xcrun", "simctl", "delete", session.udid], capture_output=True, text=True)
                print(f"Deleted {session.name}." if deleted.returncode == 0
                      else f"Could not delete {session.name} ({session.udid}): {deleted.stderr.strip()}")
                if deleted.returncode:
                    status = max(status, 125)
            started = None if window else simulator_app()
            opened = (f"{window} was already running" if window else
                      f"{started} was started by something else" if started else "no simulator view ran")
            print(f"Finished in {time.monotonic() - began:.0f} s; load averages "
                  f"{' '.join(f'{load:.0f}' for load in os.getloadavg())}; {opened}.")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
