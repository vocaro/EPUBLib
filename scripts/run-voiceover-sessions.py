#!/usr/bin/env python3
"""Run the speech sessions of one hosted job, each with a fresh verification reader.

.github/workflows/voiceover-mac.yml runs this on a GitHub runner it has prepared; see "Hosted
Mac sessions" in doc/voiceover-testing.md. The workflow's inputs arrive in the environment,
and an empty one takes the value in brackets:

VOICEOVER_STEPS          the steps of scripts/run-voiceover-mac.py, quoted as on a command line,
                         with `;` or a line break between sessions [the page-boundary session]
VOICEOVER_WIDTH          window width in points, set by `ax:width` before each session [1100]
VOICEOVER_TEXT_SIZE      text size in points at launch [23]
VOICEOVER_FLOW           paginated or scrolled [paginated]
VOICEOVER_PAUSE          the runner's --pause [5]
VOICEOVER_ADVANCE_AFTER  the runner's --advance-after [the fixed pause]
"""
import argparse
import importlib.util
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / ".build/voiceover/results"
READER = ROOT / ".build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app"
# The left column's entry line, a Next Page activated through VoiceOver, then the new page's
# entry line and its second line. Next Page is eight items left of the left column, with one
# column or two. The lines are read after the turn: VoiceOver may come back to a column at the
# character offset it had there, so a line moved before the turn can move the second entry.
BOUNDARY = ("ax:next ax:lines ax:focus=0 in line out " + "left " * 8
            + '"activate=Next Page" ax:lines ' + "right " * 8 + "in line nextline nextline")
OUTCOMES = {0: "completed", 2: "refused by the runner script", 124: "ended early or reached its deadline",
            125: "stopped"}


def runner():
    """scripts/run-voiceover-mac.py as a module, for its step words."""
    spec = importlib.util.spec_from_file_location("run_voiceover_mac", ROOT / "scripts/run-voiceover-mac.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sessions(text):
    """The step list of each session: words split as a shell would, sessions at `;` or a line break."""
    found = [[]]
    for line in text.splitlines():
        lexer = shlex.shlex(line, posix=True, punctuation_chars=";")
        lexer.whitespace_split = True
        lexer.commenters = ""
        for word in lexer:
            if word.strip(";"):
                found[-1].append(word)
            else:
                found.append([])
        found.append([])
    return [steps for steps in found if steps]


def settings():
    """The runner script's options, the reader's launch arguments and each session's steps."""
    def read(name, default, kind):
        text = os.environ.get(f"VOICEOVER_{name}", "").strip() or default
        try:
            value = kind(text)
        except ValueError:
            value = -1
        if not 0 <= value < 10000:
            raise SystemExit(f"VOICEOVER_{name} must be a number from 0 up, not {text!r}")
        return f"{value:g}"

    width, size, pause = read("WIDTH", "1100", int), read("TEXT_SIZE", "23", float), read("PAUSE", "5", float)
    flow = os.environ.get("VOICEOVER_FLOW", "").strip() or "paginated"
    if flow not in ("paginated", "scrolled"):
        raise SystemExit(f"VOICEOVER_FLOW must be paginated or scrolled, not {flow!r}")
    options = ["--pause", pause]
    if os.environ.get("VOICEOVER_ADVANCE_AFTER", "").strip():
        options += ["--advance-after", read("ADVANCE_AFTER", "", float)]
    text = os.environ.get("VOICEOVER_STEPS", "").strip()
    if not text and flow == "scrolled":
        raise SystemExit("Give the steps of a continuous-scroll session; the default session turns pages")
    try:
        lists = [[f"ax:width={width}"] + steps for steps in sessions(text or BOUNDARY)]
    except ValueError as error:
        raise SystemExit(f"VOICEOVER_STEPS: {error}")
    unknown = runner().unknown([step for steps in lists for step in steps])
    if unknown or not lists:
        raise SystemExit(f"Unknown steps: {' '.join(unknown)}" if unknown else "VOICEOVER_STEPS holds no step")
    return options, ["-SampleFlow", flow, "-SampleFontSize", size], lists


def running(name):
    return subprocess.run(["pgrep", "-x", name], capture_output=True).stdout


def fresh_reader(launch):
    """Close the previous session's reader and open a new one, as the docs ask before each case."""
    # VoiceOver ignores its shortcut while it is still quitting.
    limit = time.monotonic() + 20
    while running("VoiceOver") and time.monotonic() < limit:
        time.sleep(0.5)
    if subprocess.run(["pkill", "-x", READER.stem]).returncode == 0:
        time.sleep(6)
    subprocess.run(["open", "-na", str(READER), "--args"] + launch, check=True)
    time.sleep(8)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="print the sessions and run nothing")
    parser.add_argument("--until", type=int, metavar="EPOCH", help="when the last session must have ended")
    args = parser.parse_args()
    options, launch, lists = settings()
    for number, steps in enumerate(lists, 1):
        print(f"Session {number}: {shlex.join(launch)}; {shlex.join(options + steps)}", flush=True)
    if args.check:
        return 0
    RESULTS.mkdir(parents=True, exist_ok=True)
    summary = ["### Mac VoiceOver sessions", "", f"`{shlex.join(launch)}`, `{shlex.join(options)}`", ""]
    failures = 0
    for number, steps in enumerate(lists, 1):
        # A session takes its timeout and about 45 seconds around it.
        timeout = 300 if args.until is None else min(300, int(args.until - time.time()) - 45)
        if timeout < 60:
            failures += 1
            outcome, transcript = "not run, because the job's time was used up", "no transcript"
            summary += [f"Session {number}: {outcome}", ""]
        else:
            print(f"::group::Session {number}", flush=True)
            fresh_reader(launch)
            before = set(RESULTS.glob("mac-*.transcript.txt"))
            started = time.time()
            status = subprocess.run([sys.executable, str(ROOT / "scripts/run-voiceover-mac.py"),
                                     "--timeout", str(timeout)] + options + steps).returncode
            failures += status != 0
            written = sorted(set(RESULTS.glob("mac-*.transcript.txt")) - before)
            transcript = written[-1].name if written else "no transcript"
            outcome = f"{OUTCOMES.get(status, 'failed')} (exit {status}) in {time.time() - started:.0f} s"
            lines = written[-1].read_text().splitlines() if written else []
            print("\n".join(lines) + "\n::endgroup::", flush=True)
            # The steps and the speech alone, without the observer's lines, for the run's summary page.
            spoken = [line[11:] for line in lines if line[25:].startswith(("STEP ", "heard: ", "ADVANCE "))]
            summary += [f"<details><summary>Session {number}: {outcome}</summary>", "", "```text", *spoken, "```",
                        "", "</details>", ""]
        line = f"Session {number}: {outcome}; {transcript}; {shlex.join(launch + options + steps)}"
        print(line, flush=True)
        with (RESULTS / "sessions.txt").open("a") as record:
            record.write(line + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as page:
            page.write("\n".join(summary) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
