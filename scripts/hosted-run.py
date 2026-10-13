#!/usr/bin/env python3
"""Start a run on GitHub's hosted Mac runner, after looking at what is already there.

    python3 scripts/hosted-run.py
    python3 scripts/hosted-run.py voiceover-mac.yml -f steps='width=600 in line ; in line'
    python3 scripts/hosted-run.py unit-tests-mac.yml -f filter=ReaderCanvasViewTests -f repeat=20

GitHub runs five macOS jobs at a time for the whole account, every session's runs of both
workflows draw on them, and its queue has no priorities; see "Sharing the runner" in
doc/testing.md. With no workflow this prints the runs in flight and starts nothing. With one
it takes the place of `gh workflow run`: it starts the run from the branch checked out, or
from --ref, and prints the new run. It starts nothing, and exits with status 1, when

- the branch has two runs in flight, or one while any job is waiting for a runner;
- every unit test is asked for once, under scroll bars a pull request's run of the same commit
  already has;
- the steps of a VoiceOver run do not pass scripts/run-voiceover-sessions.py --check.

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
WORKFLOWS = ("voiceover-mac.yml", "unit-tests-mac.yml")
SLOTS = 5  # macOS jobs at once for an account on GitHub's Free, Pro and Team plans.
# Every workflow of this repository runs on the Mac runner, so every run in flight counts.
IN_FLIGHT = ("in_progress", "queued", "pending", "requested", "waiting")
FIELDS = "databaseId,status,workflowName,headBranch,event,displayTitle,createdAt"


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"gh {' '.join(arguments)}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def in_flight():
    """This repository's runs that hold a runner or wait for one, oldest first, with their jobs counted."""
    def listed(status):
        return json.loads(gh("run", "list", "--status", status, "--limit", "100", "--json", FIELDS))

    def jobs(run):
        # A run is in progress as soon as one job is: a run for main has two, on a runner each.
        return json.loads(gh("api", f"repos/{{owner}}/{{repo}}/actions/runs/{run['databaseId']}/jobs",
                             "--jq", "[.jobs[].status]"))

    # Each question to GitHub takes a second or two, so they are asked together.
    with ThreadPoolExecutor(8) as pool:
        runs = [run for found in pool.map(listed, IN_FLIGHT) for run in found]
        for run, states in zip(runs, pool.map(jobs, runs)):
            # A run so new that it has no job yet is about to wait for a runner.
            states = [state for state in states if state != "completed"] or ["queued"]
            run["running"] = states.count("in_progress")
            run["waiting"] = len(states) - run["running"]
    return sorted(runs, key=lambda run: run["createdAt"])


def rows(runs):
    now = datetime.now(timezone.utc)
    for run in runs:
        minutes = (now - datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00"))).total_seconds() / 60
        state = " and ".join(f"{run[kind]} {kind}" for kind in ("running", "waiting") if run[kind])
        title = run["displayTitle"]
        if not title.startswith(run["workflowName"]):
            title = f"{run['workflowName']}, {run['event']}: {title}"
        yield f"  {run['databaseId']}  {state}, {minutes:.0f} min old  {run['headBranch']}  {title}"


def head(ref):
    """The commit GitHub has for a branch, a tag or a commit SHA."""
    found = subprocess.run(["gh", "api", f"repos/{{owner}}/{{repo}}/commits/{ref}", "--jq", ".sha"],
                           cwd=ROOT, capture_output=True, text=True)
    if found.returncode:
        raise SystemExit(f"GitHub has no commit for {ref}; push it first")
    return found.stdout.strip()


def refusals(args, fields, branch, flight):
    """Each reason not to start the run."""
    # A push to main starts its own run, which is no session's.
    mine = [run for run in flight if run["headBranch"] == args.ref and run["event"] != "push"]
    waiting = sum(run["waiting"] for run in flight)
    if len(mine) >= (1 if waiting else 2):
        count = f"{len(mine)} runs" if len(mine) > 1 else "a run"
        rule = "a branch keeps to " + ("one while any job is waiting for a runner" if waiting else "two")
        yield "\n".join([f"{args.ref} has {count} in flight, and {rule}:", *rows(mine),
                         "Wait for one to end, or cancel one that is no longer needed with `gh run cancel RUN_ID`."])
    kinds = fields.get("scroll_bars", "legacy")
    if (args.workflow == "unit-tests-mac.yml" and not fields.get("filter") and fields.get("repeat", "1") == "1"
            and kinds in ("legacy", "both")):
        commit = head(fields.get("ref") or args.ref)
        tested = [run for run in json.loads(gh(
            "run", "list", "--workflow", args.workflow, "--commit", commit, "--event", "pull_request",
            "--json", "databaseId,status,conclusion"))
            if run["status"] != "completed" or run["conclusion"] in ("success", "failure")]
        if tested:
            run = tested[0]
            yield (f"A pull request's run already has every test of {commit[:7]} under legacy scroll bars: "
                   f"{run['databaseId']}, {run['conclusion'] or run['status']}. Read it with `gh run view "
                   f"{run['databaseId']}`" + ("; `-f scroll_bars=overlay` adds the other kind." if kinds == "both" else "."))
    if args.workflow == "voiceover-mac.yml" and args.ref == branch:
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
    running, waiting = (sum(run[kind] for run in flight) for kind in ("running", "waiting"))
    print(f"Hosted Mac jobs of this repository: {running} running and {waiting} waiting for a runner. "
          f"GitHub runs {SLOTS} macOS jobs at a time for the whole account.")
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
