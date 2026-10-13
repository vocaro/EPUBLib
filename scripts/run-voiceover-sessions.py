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
VOICEOVER_LAUNCH         further launch arguments of the reader, quoted as on a command line,
                         such as `-SampleHref OPS/labels.xhtml` [none]
VOICEOVER_PAUSE          the runner's --pause [5]
VOICEOVER_ADVANCE_AFTER  the runner's --advance-after [the fixed pause]

A session has the last six as given there unless its own words say otherwise: `width=600`,
`text_size=17`, `flow=scrolled`, `"launch=-SampleHref OPS/labels.xhtml"`, `pause=3` or
`advance_after=0.5`, in any order before its first step. One job can then hear sessions that
differ in them, where each used to need a job, a build and a runner of its own. A session of
such words alone is the page-boundary session with them. `launch=` with nothing after it is no
further argument, and `advance_after=` the fixed pause.
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
# The left column's entry line and two lines down, a Next Page activated through VoiceOver, then
# the new page's entry line and its second line. Next Page is eight items left of the left
# column, with one column or two. The entry line after the turn must be the page's first: a
# reader whose window posts the spread's layout change comes back at the line VoiceOver had
# reached before the turn (#337). VoiceOver is brought to the column by a focus change from the
# search field, because a session can open with its cursor already on the text, and it then
# comes back at the first line whatever the reader posts.
BOUNDARY = ("ax:next ax:lines ax:focus=search ax:focus=0 in line nextline nextline out " + "left " * 8
            + '"activate=Next Page" ax:lines ' + "right " * 8 + "in line nextline nextline")
# What a session can set for itself, with the value an empty input takes. Each arrives as
# VOICEOVER_NAME and is written NAME=VALUE in a session's own words.
DEFAULTS = {"width": "1100", "text_size": "23", "flow": "paginated", "launch": "", "pause": "5", "advance_after": ""}
OUTCOMES = {0: "completed", 2: "refused by the runner script", 124: "ended early or reached its deadline",
            125: "stopped", 126: "VoiceOver not restored"}


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


def checked(name, text, where):
    """A setting as the runner script and the reader take it; `where` names it in a refusal."""
    if name == "flow":
        if text not in ("paginated", "scrolled"):
            raise SystemExit(f"{where} must be paginated or scrolled, not {text!r}")
        return text
    if name == "launch":
        try:
            return shlex.join(shlex.split(text))
        except ValueError as error:
            raise SystemExit(f"{where}: {error}")
    if name == "advance_after" and not text:
        return text
    try:
        value = (int if name == "width" else float)(text)
    except ValueError:
        value = -1
    if not 0 <= value < 10000:
        raise SystemExit(f"{where} must be a number from 0 up, not {text!r}")
    return f"{value:g}"


def settings():
    """Each session's settings and steps: the inputs, changed by the settings the session opens with."""
    inputs = {name: checked(name, os.environ.get(f"VOICEOVER_{name.upper()}", "").strip() or default,
                            f"VOICEOVER_{name.upper()}") for name, default in DEFAULTS.items()}
    text = os.environ.get("VOICEOVER_STEPS", "").strip()
    try:
        lists = sessions(text) if text else [[]]
    except ValueError as error:
        raise SystemExit(f"VOICEOVER_STEPS: {error}")
    if not lists:
        raise SystemExit("VOICEOVER_STEPS holds no step")
    found = []
    for number, words in enumerate(lists, 1):
        chosen, own, steps = dict(inputs), set(), []
        for word in words:
            name, equals, value = word.partition("=")
            if not equals or name not in DEFAULTS:
                steps.append(word)
            elif steps:
                # Nothing changes the reader's launch arguments once it is open, so a setting
                # among the steps would be one the session does not have.
                raise SystemExit(f"Session {number}: {word} follows a step; a session's settings come before its steps")
            elif name in own:
                raise SystemExit(f"Session {number}: {name} is given twice")
            else:
                chosen[name] = checked(name, value, f"Session {number}: {name}")
                own.add(name)
        if not steps and chosen["flow"] == "scrolled":
            raise SystemExit(f"Session {number}: give the steps of a continuous-scroll session; "
                             "the default session turns pages")
        found.append((chosen, steps or sessions(BOUNDARY)[0]))
    unknown = runner().unknown([step for _, steps in found for step in steps])
    if unknown:
        raise SystemExit(f"Unknown steps: {' '.join(unknown)}")
    return found


def described(chosen):
    """A session's settings in words, for the log, sessions.txt and the summary page."""
    further = f", {chosen['launch']}" if chosen["launch"] else ""
    pace = f", next key {chosen['advance_after']} s after a phrase" if chosen["advance_after"] else ""
    return (f"{chosen['width']} wide at {chosen['text_size']} points, {chosen['flow']}{further}, "
            f"{chosen['pause']} s pause{pace}")


def command(chosen, steps):
    """The reader's launch arguments for a session, and the runner script's options and steps."""
    options = ["--pause", chosen["pause"]]
    if chosen["advance_after"]:
        options += ["--advance-after", chosen["advance_after"]]
    launch = ["-SampleFlow", chosen["flow"], "-SampleFontSize", chosen["text_size"]] + shlex.split(chosen["launch"])
    return launch, options + [f"ax:width={chosen['width']}"] + steps


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
    found = [(described(chosen), *command(chosen, steps)) for chosen, steps in settings()]
    for number, (label, launch, rest) in enumerate(found, 1):
        print(f"Session {number}: {label}; {shlex.join(launch)}; {shlex.join(rest)}", flush=True)
    if args.check:
        return 0
    RESULTS.mkdir(parents=True, exist_ok=True)
    summary = ["### Mac VoiceOver sessions", ""]
    failures = 0
    for number, (label, launch, rest) in enumerate(found, 1):
        # A session takes its timeout and about 45 seconds around it.
        timeout = 300 if args.until is None else min(300, int(args.until - time.time()) - 45)
        if timeout < 60:
            failures += 1
            outcome, transcript = "not run, because the job's time was used up", "no transcript"
            summary += [f"Session {number}: {label}; {outcome}", ""]
        else:
            print(f"::group::Session {number}: {label}", flush=True)
            fresh_reader(launch)
            before = set(RESULTS.glob("mac-*.transcript.txt"))
            started = time.time()
            status = subprocess.run([sys.executable, str(ROOT / "scripts/run-voiceover-mac.py"),
                                     "--timeout", str(timeout)] + rest).returncode
            failures += status != 0
            written = sorted(set(RESULTS.glob("mac-*.transcript.txt")) - before)
            transcript = written[-1].name if written else "no transcript"
            outcome = f"{OUTCOMES.get(status, 'failed')} (exit {status}) in {time.time() - started:.0f} s"
            lines = written[-1].read_text().splitlines() if written else []
            print("\n".join(lines) + "\n::endgroup::", flush=True)
            # The steps and the speech alone, without the observer's lines, for the run's summary page.
            spoken = [line[11:] for line in lines
                      if line[25:].startswith(("STEP ", "heard: ", "ADVANCE ", "NOT_RESTORED "))]
            summary += [f"<details><summary>Session {number}: {label}; {outcome}</summary>", "", "```text",
                        *spoken, "```", "", "</details>", ""]
        line = f"Session {number}: {label}; {outcome}; {transcript}; {shlex.join(launch + rest)}"
        print(line, flush=True)
        with (RESULTS / "sessions.txt").open("a") as record:
            record.write(line + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as page:
            page.write("\n".join(summary) + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
