"""Exercise hosted-run's CLI against fake gh and git, without dispatching a job."""
from datetime import datetime, timezone
import json

from support import ScriptTestCase

BRANCH = "codex/script-tests"
HEAD = "a" * 40
STEPS = "steps=width=600 text_size=17 in line ; in line"
GH = '''import json, os, sys
from pathlib import Path
scenario = json.loads(Path(os.environ["FAKE_GH"]).read_text())
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["run", "list"] and "--status" in args:
    if scenario.get("list_fails"):
        sys.stderr.write("could not read the queue\\n")
        sys.exit(1)
    status = args[args.index("--status") + 1]
    repository = args[args.index("--repo") + 1] if "--repo" in args else None
    runs = scenario.get("repository_runs", {}).get(repository, scenario.get("runs", []))
    print(json.dumps([run for run in runs if run["status"] == status]))
elif args[0] == "api" and "/commits/" in args[1]:
    ref = args[1].split("/commits/")[1]
    if ref not in scenario["commits"]:
        sys.stderr.write("gh: No commit found for SHA (HTTP 422)\\n")
        sys.exit(1)
    print(scenario["commits"][ref])
elif args[:2] == ["workflow", "run"]:
    if scenario.get("dispatch_fails"):
        sys.stderr.write("HTTP 422: Unexpected inputs provided\\n")
        sys.exit(1)
    print(scenario.get("dispatch_output", "https://github.com/vocaro/EPUBLib/actions/runs/999"))
elif args[:2] == ["run", "list"] and "--branch" in args:
    print(json.dumps(scenario.get("newest", [])))
else:
    sys.stderr.write(f"fake gh: unexpected {args}\\n")
    sys.exit(9)
'''
GIT = f'''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args == ["branch", "--show-current"]:
    print({BRANCH!r})
elif args == ["rev-parse", "HEAD"]:
    print({HEAD!r})
elif args == ["config", "--local", "--get-all", "vocaroEngineering.hostedRepository"]:
    scenario = json.loads(Path(os.environ["FAKE_GH"]).read_text())
    if scenario.get("local_config_fails"):
        sys.stderr.write("cannot read enrollment")
        sys.exit(128)
    names = scenario.get("local_repositories", [])
    for name in names: print(name)
    sys.exit(0 if names else 1)
else:
    raise AssertionError(args)
'''


def run_of(number, status, branch=BRANCH):
    return {"databaseId": number, "status": status, "headBranch": branch,
            "displayTitle": f"Mac VoiceOver, {branch}", "createdAt": "2026-10-13T03:00:00Z"}


class HostedRunTests(ScriptTestCase):
    def setUp(self):
        super().setUp()
        self.tool("gh", GH)
        self.tool("git", GIT)

    def invoke(self, scenario, arguments, status=0, dispatched=True, shows=(), ref=BRANCH, forwarded=None):
        scenario = dict(scenario)
        scenario.setdefault("commits", {BRANCH: HEAD, "main": "b" * 40})
        source, log = self.root / "scenario.json", self.root / "gh.jsonl"
        source.write_text(json.dumps(scenario))
        log.unlink(missing_ok=True)
        result = self.run_script("hosted-run.py", *arguments, FAKE_GH=str(source), FAKE_GH_LOG=str(log))
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, status, output)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertFalse(any("fake gh: unexpected" in line for line in output.splitlines()), output)
        sent = [call for call in calls if call[:2] == ["workflow", "run"]]
        self.assertEqual(len(sent), int(dispatched), output)
        if dispatched:
            if forwarded is None:
                forwarded = [argument for argument in arguments[1:] if argument != "--force"]
            self.assertEqual(sent[0], ["workflow", "run", "voiceover-mac.yml", "--ref", ref]
                             + forwarded, output)
        for text in shows:
            self.assertIn(text, output)
        self.output = output
        return calls

    def test_queue_limits_and_force(self):
        cases = [
            ([], False, 0, "0 on a runner and 0 waiting"),
            ([run_of(1, "in_progress")], False, 0, "1 on a runner and 0 waiting"),
            ([run_of(1, "in_progress"), run_of(2, "in_progress")], False, 1,
             "has 2 runs in flight, and a branch keeps to two"),
            ([run_of(1, "in_progress"), run_of(2, "queued")], True, 0,
             "Starting with --force all the same."),
            ([run_of(1, "queued", "other")], False, 0, "0 on a runner and 1 waiting"),
        ]
        for waiting in ("queued", "pending", "requested", "waiting"):
            cases += [
                ([run_of(1, "in_progress"), run_of(2, waiting, "other")], False, 1,
                 "keeps to one while any run is waiting"),
                ([run_of(1, waiting)], False, 1, "has a run in flight"),
            ]
        for runs, force, status, message in cases:
            with self.subTest(runs=runs, force=force):
                arguments = ["voiceover-mac.yml", "-f", STEPS, "-f", "pause=4"]
                if force:
                    arguments += ["--force"]
                self.invoke({"runs": runs}, arguments, status, status == 0, [message])

    def test_local_inputs_are_checked_before_dispatch(self):
        for field, message in [
            ("steps=in line ; width=wide in", "Session 2: width must be a number"),
            ("flow=sideways", "VOICEOVER_FLOW must be paginated or scrolled"),
            ("steps=in lien", "Unknown steps: lien"),
        ]:
            with self.subTest(field=field):
                self.invoke({}, ["voiceover-mac.yml", "-f", field], 1, False,
                            ["Not started. The sessions would be refused on the runner:", message])

    def test_force_overrides_local_validation_without_being_forwarded(self):
        self.invoke({}, ["voiceover-mac.yml", "-f", "steps=in lien", "--force"],
                    shows=["Starting with --force all the same.", "Unknown steps: lien"])

    def test_unreadable_queue_never_dispatches(self):
        self.invoke({"list_fails": True}, ["voiceover-mac.yml"], 1, False, ["could not read the queue"])

    def test_launch_arguments_and_default_settings_are_reported(self):
        self.invoke({}, ["voiceover-mac.yml", "-f",
                         'steps="launch=-SampleHref OPS/labels.xhtml" in line ; in line'], shows=[
                             "Session 1: 1100 wide at 23 points, paginated, -SampleHref OPS/labels.xhtml, 5 s pause",
                             "Session 2: 1100 wide at 23 points, paginated, 5 s pause", "Started run 999"])

    def test_another_ref_skips_this_checkouts_step_validation(self):
        self.invoke({}, ["voiceover-mac.yml", "--ref", "main", "-f", "steps=in lien"],
                    ref="main", forwarded=["-f", "steps=in lien"])

    def test_missing_remote_branch_is_refused(self):
        self.invoke({"commits": {}}, ["voiceover-mac.yml"], 1, False,
                    ["GitHub has no commit for", "push it first"])

    def test_checkout_ahead_of_remote_reports_which_commit_runs(self):
        self.invoke({"commits": {BRANCH: "f" * 40}}, ["voiceover-mac.yml"],
                    shows=["at fffffff and this checkout is at aaaaaaa", "the run uses what is pushed"])

    def test_dispatch_without_url_finds_recent_run(self):
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        calls = self.invoke({"dispatch_output": "Created workflow_dispatch event",
                             "newest": [{"databaseId": 4242, "createdAt": now}]},
                            ["voiceover-mac.yml"], shows=["Started run 4242"])
        self.assertTrue(any("--branch" in call and "--event" in call for call in calls))

    def test_dispatch_failure_is_reported(self):
        self.invoke({"dispatch_fails": True}, ["voiceover-mac.yml", "-f", "nonsense=1"],
                    1, True, ["Unexpected inputs provided"])

    def test_no_workflow_only_lists_runs_oldest_first(self):
        older = dict(run_of(2, "queued"), createdAt="2026-10-12T03:00:00Z")
        calls = self.invoke({"runs": [run_of(1, "in_progress", "other"), older]},
                            [], 0, False, ["1 on a runner and 1 waiting", "  1  on a runner,", "  2  waiting,"])
        self.assertEqual(len(calls), 5)
        self.assertTrue(all(call[:2] == ["run", "list"] and "--status" in call for call in calls))
        self.assertLess(self.output.index("  2  waiting,"), self.output.index("  1  on a runner,"))

    def test_invalid_cli_never_calls_gh(self):
        for arguments, message in [(["unit-tests-mac.yml"], "invalid choice"),
                                   (["voiceover-mac.yml", "-f", "steps"], "-f takes KEY=VALUE")]:
            with self.subTest(arguments=arguments):
                calls = self.invoke({}, arguments, 2, False, [message])
                self.assertEqual(calls, [])

    def test_private_queues_are_additive_local_enrollment(self):
        own = "vocaro/EPUBLib"
        private = "example/private-project"
        calls = self.invoke({"local_repositories": [private, own, private],
                             "repository_runs": {own: [run_of(1, "in_progress")],
                                                 private: [run_of(2, "queued", "other")]}},
                            ["voiceover-mac.yml"], 1, False,
                            ["keeps to one while any run is waiting"])
        queued = [call[call.index("--repo") + 1] for call in calls if "--repo" in call]
        self.assertEqual(queued.count(own), 5)
        self.assertEqual(queued.count(private), 5)

    def test_other_repository_branch_names_do_not_count_as_ours(self):
        private = "example/private-project"
        self.invoke({"local_repositories": [private],
                     "repository_runs": {"vocaro/EPUBLib": [],
                                         private: [run_of(1, "in_progress"), run_of(2, "in_progress")]}},
                    ["voiceover-mac.yml"], shows=["Started run 999"])

    def test_invalid_or_unreadable_local_enrollment_never_queries_or_dispatches(self):
        for scenario, message in [({"local_repositories": ["invalid"]}, "Invalid local hosted"),
                                  ({"local_config_fails": True}, "Cannot read local hosted")]:
            calls = self.invoke(scenario, ["voiceover-mac.yml"], 1, False, [message])
            self.assertEqual(calls, [])
