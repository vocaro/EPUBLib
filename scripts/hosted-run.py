#!/usr/bin/env python3
"""Start a Mac VoiceOver run on GitHub's hosted runner, after looking at what is already there.

    python3 scripts/hosted-run.py
    python3 scripts/hosted-run.py voiceover-mac.yml -f steps='width=600 in line ; in line'

GitHub runs five macOS jobs at a time for the whole account, every session's runs draw on
them, and its queue has no priorities; see "Sharing the runner" in doc/testing.md.
With no workflow this prints the runs in flight and starts nothing. With one it takes the
place of `gh workflow run`: it starts the run from the branch checked out, or from --ref, and
prints the new run. It starts nothing, and exits with status 1, when

- the branch has two runs in flight, or one while any run is waiting for a runner;
- the steps do not pass scripts/run-voiceover-sessions.py --check.

--force starts the run whatever was found.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
# The one workflow the runner is for; see "The hosted runner" in AGENTS.md.
WORKFLOWS = ("voiceover-mac.yml",)
SLOTS = 5  # macOS jobs at once for an account on GitHub's Free, Pro and Team plans.
IN_FLIGHT = ("in_progress", "queued", "pending", "requested", "waiting")
FIELDS = "databaseId,status,headBranch,displayTitle,createdAt"


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"gh {' '.join(arguments)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def in_flight():
    """This repository's runs that hold a runner or wait for one, oldest first."""
    def listed(status):
        return json.loads(gh("run", "list", "--status", status, "--limit", "100", "--json", FIELDS))

    # Each question to GitHub takes a second or two, so they are asked together.
    with ThreadPoolExecutor(len(IN_FLIGHT)) as pool:
        runs = [run for found in pool.map(listed, IN_FLIGHT) for run in found]
    return sorted(runs, key=lambda run: run["createdAt"])


def rows(runs):
    now = datetime.now(timezone.utc)
    for run in runs:
        minutes = (now - datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00"))).total_seconds() / 60
        state = "on a runner" if run["status"] == "in_progress" else "waiting"
        yield f"  {run['databaseId']}  {state}, {minutes:.0f} min old  {run['headBranch']}  {run['displayTitle']}"


def head(ref):
    """The commit GitHub has for a branch or a tag."""
    found = subprocess.run(["gh", "api", f"repos/{{owner}}/{{repo}}/commits/{ref}", "--jq", ".sha"],
                           cwd=ROOT, capture_output=True, text=True)
    if found.returncode:
        raise SystemExit(f"GitHub has no commit for {ref}; push it first")
    return found.stdout.strip()


def refusals(args, fields, branch, flight):
    """Each reason not to start the run."""
    mine = [run for run in flight if run["headBranch"] == args.ref]
    waiting = any(run["status"] != "in_progress" for run in flight)
    if len(mine) >= (1 if waiting else 2):
        count = f"{len(mine)} runs" if len(mine) > 1 else "a run"
        rule = "a branch keeps to " + ("one while any run is waiting for a runner" if waiting else "two")
        yield "\n".join([f"{args.ref} has {count} in flight, and {rule}:", *rows(mine),
                         "Wait for one to end, or cancel one that is no longer needed with `gh run cancel RUN_ID`."])
    if args.ref == branch:
        # On the runner the same check comes after the wait for a runner. It is this checkout's
        # script, so it is left out for a run started from another branch.
        environment = {name: value for name, value in os.environ.items() if not name.startswith("VOICEOVER_")}
        environment.update({f"VOICEOVER_{name.upper()}": value for name, value in fields.items()})
        check = subprocess.run([sys.executable, str(ROOT / "scripts/run-voiceover-sessions.py"), "--check"],
                               env=environment, capture_output=True, text=True)
        print(check.stdout, end="")
        if check.returncode:
            yield f"The sessions would be refused on the runner: {check.stderr.strip()}"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("workflow", nargs="?", choices=WORKFLOWS,
                        help="omit it to see the runs in flight and start nothing")
    parser.add_argument("-r", "--ref", help="the branch whose workflow file is used [the branch checked out]")
    parser.add_argument("-f", "--raw-field", dest="fields", action="append", default=[], metavar="KEY=VALUE",
                        help="an input of the workflow, as for `gh workflow run`")
    parser.add_argument("--force", action="store_true", help="start the run whatever was found")
    args = parser.parse_args()
    if any("=" not in field for field in args.fields):
        parser.error("-f takes KEY=VALUE")
    fields = dict(field.partition("=")[::2] for field in args.fields)

    flight = in_flight()
    running = sum(run["status"] == "in_progress" for run in flight)
    print(f"Hosted Mac runs of this repository: {running} on a runner and {len(flight) - running} waiting "
          f"for one. GitHub runs {SLOTS} macOS jobs at a time for the whole account.")
    if not args.workflow:
        print("\n".join(rows(flight)))
        return 0

    branch = subprocess.run(["git", "branch", "--show-current"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    args.ref = args.ref or branch
    if not args.ref:
        parser.error("No branch is checked out; name one with --ref")
    pushed = head(args.ref)
    here = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if args.ref == branch and pushed != here:
        print(f"GitHub has {branch} at {pushed[:7]} and this checkout is at {here[:7]}: the run uses what is pushed.")

    found = list(refusals(args, fields, branch, flight))
    for reason in found:
        print(("Starting with --force all the same. " if args.force else "Not started. ") + reason, file=sys.stderr)
    if found and not args.force:
        return 1

    began = datetime.now(timezone.utc) - timedelta(seconds=30)
    started = subprocess.run(["gh", "workflow", "run", args.workflow, "--ref", args.ref]
                             + [word for field in args.fields for word in ("-f", field)],
                             cwd=ROOT, capture_output=True, text=True)
    if started.returncode:
        print(started.stderr.strip() or started.stdout.strip(), file=sys.stderr)
        return started.returncode
    # gh prints the new run's address when GitHub returns one. Otherwise it is the branch's newest.
    run = re.search(r"/actions/runs/(\d+)", started.stdout + started.stderr)
    run = run and run[1]
    for _ in range(10):
        if run:
            break
        time.sleep(2)
        newest = json.loads(gh("run", "list", "--workflow", args.workflow, "--branch", args.ref, "--event",
                               "workflow_dispatch", "--limit", "1", "--json", "databaseId,createdAt"))
        if newest and newest[0]["createdAt"] >= began.strftime("%Y-%m-%dT%H:%M:%SZ"):
            run = newest[0]["databaseId"]
    if not run:
        print(f"Started. Find the run with `gh run list --workflow {args.workflow} --branch {args.ref} --limit 3`.")
        return 0
    print(f"Started run {run}. Follow it with `gh run watch {run} --exit-status`, and cancel it with "
          f"`gh run cancel {run}` if it is no longer needed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
