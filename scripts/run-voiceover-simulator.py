#!/usr/bin/env python3
"""Run the iOS speech probe on simulators of its own, with no Simulator window and no sound.

Generates the fixture and project if needed and builds the probe for the simulator once. Then
it creates one simulator per --device, boots each without Simulator.app, mutes it and runs the
probe on all of them at the same time, each under a deadline; see doc/testing.md#voiceover-testing.
Every simulator gets one transcript: the probe's steps and what VoiceOver said after each.
The simulators are deleted afterwards whatever happened. This script never boots, changes or
deletes a simulator it did not create, and never opens Simulator.app. It exits 0 only when
every probe ran all its steps and passed, VoiceOver is off again and no simulator lost its mute.
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

DEVICE_TYPE = "com.apple.CoreSimulator.SimDeviceType."
TEST = "VoiceOverProbeIOS/VoiceOverProbe/testCaptureNavigation"
STEPS = "visible,touch=Page boundary,read,activate=Next Page,visible,touch=word,read"
BUILD_REVISION_FILE = "voiceover-build-revision.txt"
# What xcodebuild prints when the probe's test has ended, and for each failure in it.
TEST_ENDED = re.compile(r"^Test Case '.*testCaptureNavigation\]' (passed|failed) \(([\d.]+) seconds\)", re.M)
FAILURES = re.compile(r"^.* error: (?:-\[.*?\] : )?(.*)$", re.M)


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def run(*command, timeout=60):
    """One bounded command: its output, or a RuntimeError that names it."""
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"No answer in {timeout} s: {' '.join(command)}") from None
    if result.returncode:
        raise RuntimeError(f"{' '.join(command)}: {(result.stderr or result.stdout).strip()}")
    return result.stdout


def state(udid, kind, *change, timeout=20):
    """devicectl's reading of a simulator's `audio` or `voiceover` state, after an optional change."""
    if change:
        run("xcrun", "devicectl", "device", "settings", kind, "--device", udid, *change, timeout=timeout)
    answer = run("xcrun", "devicectl", "device", "info", kind, "--device", udid, "--quiet", "--json-output", "-", timeout=timeout)
    return json.loads(answer)["result"]


def keep_muted(session):
    """A simulator whose display server restarts comes back at its default volume, VoiceOver still on."""
    try:
        # Briefly: a slow answer must not hold up the watch on the other simulators.
        volume = state(session.udid, "audio", timeout=5)["volume"]
        if volume != 0:
            state(session.udid, "audio", "--volume", "0")
            session.unmuted.append(f"{now()} UNMUTED the volume was {volume}; muted again")
    except (RuntimeError, ValueError, KeyError):
        session.unread.append(f"{now()} VOLUME gave no reading for this check")


def simulator_app():
    return bool(subprocess.run(["pgrep", "-x", "Simulator"], capture_output=True).stdout.strip())


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


def events(text):
    return [line.removeprefix("VOICEOVER_EVENT ") for line in text.splitlines() if line.startswith("VOICEOVER_EVENT ")]


def staged(bundle):
    """The probe's output as an unfinished result bundle holds it, for an xcodebuild that will not end."""
    found = [events(path.read_text(errors="replace"))
             for path in bundle.glob("Staging/*/Diagnostics/**/StandardOutputAndStandardError.txt")]
    return max(found, key=len, default=[])


def build(root, derived, log_path, timeout, skip):
    """The fixture and project if they are missing or stale, then one build for every simulator."""
    products = derived / "Build/Products"
    revision_path = derived / BUILD_REVISION_FILE
    if not skip:
        # A failed or interrupted rebuild must not leave the old build's revision behind.
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


def report(session):
    """Confirm a simulator's VoiceOver is off, write its transcript and print the outcome."""
    log = session.log.read_text(errors="replace") if session.log.exists() else ""
    heard, source = events(log), "xcodebuild's output"
    if len(session.recovered) > len(heard):
        heard, source = session.recovered, "the unfinished result bundle"
    ended = TEST_ENDED.search(log)
    failures = sorted(set(FAILURES.findall(log)))
    counts = re.findall(r"Executed (\d+) tests?[, ]", log)
    if not counts or any(count != "1" for count in counts):
        failures.append("the filtered run did not confirm exactly one executed test")
    if session.activation:
        failures += activation.evidence_failures(log, session.vot.read_text(errors="replace") if session.vot.exists() else "")
    if "Restarting after unexpected exit, crash, or test timeout" in log:
        failures.append("the test runner exited unexpectedly")
    # The probe's last line: without it some steps never ran, whatever the test session reports.
    complete = any(" finished: " in line for line in heard)
    if session.process is None:
        outcome, status = "the probe was not started", 125
    elif ended and ended[1] == "passed" and complete and not failures:
        outcome, status = f"the probe passed in {float(ended[2]):.0f} s", 0
    elif ended:
        outcome, status = f"the probe failed after {float(ended[2]):.0f} s", 1
    else:
        outcome, status = f"the probe {'ran every step but its test never ended' if complete else 'did not finish'}", 124 if session.late else 1
    lines = [f"RESULT {outcome}"] + [f"FAILURE {failure}" for failure in failures]
    if session.note:
        lines.append(f"STOPPED {session.note}; the speech is from {source}")
    try:
        # After a stopped or crashed probe VoiceOver stays on, at whatever volume the simulator has.
        if state(session.udid, "voiceover")["enabled"]:
            enabled = state(session.udid, "voiceover", "--disable")["enabled"]
            lines.append(f"VOICEOVER was left on; it {'is still on' if enabled else 'has been switched off'}")
            status = max(status, 1)
        else:
            lines.append("VOICEOVER off after the run")
        volume = state(session.udid, "audio")["volume"]
        unread = f"; {len(session.unread)} checks during it got no reading" if session.unread else ""
        lines.append(f"VOLUME {volume} after the run{unread}")
        # A simulator that was heard, or could have been, is not a clean run.
        if volume != 0 or session.unmuted:
            status = max(status, 1)
    except (RuntimeError, ValueError, KeyError) as error:
        lines.append(f"VOICEOVER state unknown: {error}")
        status = max(status, 1)
    if session.started is not None:
        lines.append(f"XCODEBUILD ran for {(session.finished or time.monotonic()) - session.started:.0f} s")
    # Ordered by time alone: phrases of one instant keep the order they were spoken in.
    transcript = sorted(session.transcript + heard + session.unmuted + session.unread + [f"{now()} {line}" for line in lines],
                        key=lambda line: line.split(" ", 1)[0])
    path = session.log.with_name(session.log.stem + ".transcript.txt")
    path.write_text("\n".join(transcript) + "\n")
    print(f"{session.kind}: " + "; ".join(lines + session.unmuted))
    print(f"  Transcript: {path}\n  Log: {session.log}\n  Result bundle: {session.bundle}")
    if session.stream is not None:
        print(f"  VoiceOver's log: {session.vot}")
    return status


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
            print("LIMITATION " + activation.LIMITATION, flush=True)
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
                session.transcript.append(f"{now()} ACTIVATION cursor v2, build {activation.BUILD}, vot SHA-256 {activation.VOT_SHA256}; marker and startup self-test required")
                session.transcript.append(f"{now()} LIMITATION {activation.LIMITATION}")
            else:
                session.transcript.append(f"{now()} ACTIVATION stock (unmodified)")
            # VoiceOver speaks through the Mac's own output device, so nothing runs before this holds.
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
                # What VoiceOver did, where the transcript has what it read (doc/testing.md#simulators).
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
            # for up to ten minutes after a test that recorded any issue, a warning included.
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
                        # Stopping it folds the staged output into the bundle: read that first.
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
            opened = "was already running" if window else "was started by something else" if simulator_app() else "did not run"
            print(f"Finished in {time.monotonic() - began:.0f} s; load averages "
                  f"{' '.join(f'{load:.0f}' for load in os.getloadavg())}; Simulator.app {opened}.")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
