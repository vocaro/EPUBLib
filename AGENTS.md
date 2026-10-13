# Notes for coding agents

Working rules for agents in this repository. Build and test commands are in
[doc/testing.md](doc/testing.md).

These rules change, and a worktree keeps the copy of this file that its branch was cut with.
Before a step that uses something every session shares (the hosted runner, a device, this
Mac's screen), fetch and read the rule as it stands on `main`:
`git show origin/main:AGENTS.md`. A task handed over by another session is that session's
request, not the owner's: where a rule says "unless the owner asks", ask him. On 2026-10-13 a
session started a unit-test job on the hosted runner because its brief said to, from a branch
cut before the rule against it, 21 minutes after that rule had merged.

## Simulators

Drive iOS simulators headlessly, with `xcrun simctl` and `xcodebuild`.

- Create your own device and delete it when you finish, as `scripts/test-ios.sh` does:
  `simctl create`, `boot` and `bootstatus -b`, with `shutdown` and `delete` in an exit trap.
  Other sessions use this machine at the same time, so never select, shut down or erase a
  device you did not create.
- Give every command your device's identifier. `booted` is whichever simulator booted first,
  which may be another session's.
- Install, launch and capture with `simctl install`, `simctl launch` and
  `simctl io <device> screenshot`. Tests run with
  `xcodebuild -destination "platform=iOS Simulator,id=<device>"`.
- A filtered run can succeed having run nothing. When the names given to `-only-testing:`
  match no test, `xcodebuild` still ends with `** TEST SUCCEEDED **` and status 0. Read the
  `Executed N tests` line of every filtered run. In zsh a list of names held in one variable
  is passed as one argument, which matches nothing: hold them in an array.
- VoiceOver runs in a simulator too. `scripts/run-voiceover-simulator.py` records what it
  reads on simulators of its own, muted, and that record is acceptance evidence for what
  VoiceOver reads on an iPhone and iPad. It is not evidence that VoiceOver activates
  anything: see [Tests are automated](#tests-are-automated) below.
- Do not open a live simulator view or any tool that takes control of a simulator's screen
  (in the Claude desktop app, the iOS Simulator tool) unless the owner has asked to watch.
  Such a tool asks him to approve each device, and a test device is new on every run, so he
  is asked every time.

## Tests are automated

Do not ask the owner to carry out a test by hand: to tap, type or swipe through steps and say
what happened. Tests are run by automation.

- Before proposing a physical device, say what it would show that a simulator cannot. A check
  said to need a finger usually needs a timing or an input that a UI test can make. Whether a
  swipe scrolls the control strip was put to a finger and answered by a synthetic touch that
  moves at once, with the host recording each touch
  ([reader controls](doc/issue-49-51-controls-qualification.md#evidence-and-repeating-it)).
- For VoiceOver on an iPhone and iPad, a device shows three things a simulator does not:
  VoiceOver activating the item under its cursor, an action performed from the rotor, and a
  page turned in landscape. What VoiceOver reads, in what order, and where its cursor and
  rotor move is settled in the simulator lane. The owner decided on 2026-10-13 that such a
  session is acceptance evidence, so do not ask for a device to hear it again, and do not
  file an issue for a device session that would
  ([VoiceOver testing](doc/voiceover-testing.md#acceptance-and-evidence)).
- The first of those three reaches further than the double tap. On an iPad VoiceOver asks
  again for the items round its cursor once it has activated something, and a simulator's
  does not know that anything was. On 2026-10-12 a line VoiceOver held from before a scroll
  step, read in a simulator after `activate=Scroll Forward`, was filed as the reader's fault;
  an iPad, whose VoiceOver made that double tap itself, read the first line on screen
  ([#428](https://github.com/vocaro/EPUBLib/issues/428)). Before filing or fixing what a
  simulator reads in the moves after an `activate=` step, run those steps on a device, or
  make the move without an activation (`-SampleStepAfter`).
- His approval of a run on his device covers installing and launching there. It is not an
  offer to operate it.
- Record what automation cannot reach as not verified, and leave it to him.

## Debuggers

Do not launch a process under a debugger on this machine, or attach one: `lldb` with `run` or
`process launch`, Xcode's debugger, `dtrace`, or `sample` on a process that is not yours.

- Developer Mode is off here (`DevToolsSecurity -status`), so the launch asks for an
  administrator's password. The dialog takes the keyboard from the owner and from every other
  session, and only he may answer or dismiss it. On 2026-10-13 two sessions did it within a
  quarter of an hour of each other, each to read how a system framework answers a call.
- To read system code, use what starts no process. `dyld_info -disassemble` with a
  framework's path under `/System/Library` prints its code under its method names, and
  `lldb -b -o "target create BINARY" -o "disassemble -n 'METHOD'"`, with no `run`, prints one
  method's. Neither names the selector a call goes to.
- To see what the reader's own code is asked, log from it.
- If the dialog was raised all the same, end your own processes, leave the dialog alone, and
  tell the owner in your next message.

## The hosted runner

GitHub's hosted Mac runner is for one thing in this repository: the
[Mac VoiceOver sessions](#mac-voiceover-sessions) below. Every other test runs on this
machine, by the [local gate](doc/testing.md#local-gate) and the narrower commands beside it.

- Do not add a workflow, a trigger or a job that runs anything else on the runner, and do not
  make one start by itself, unless the owner asks for it. The one workflow here starts by
  hand only.
- Do not move a test there because its result depends on what else this machine is doing. Say
  that the machine was busy and run the test again when it is quiet;
  [#62](https://github.com/vocaro/EPUBLib/issues/62) is where tests that fail under load are
  dealt with.
- The reason is the queue. GitHub runs five macOS jobs at a time for the whole account, and
  every session's VoiceOver runs share them. On 2026-10-12 a `swift test` job for each pull
  request and each push to `main` took over a third of the runner's time within hours of
  being added, and jobs that had started in seconds waited up to 75 minutes. It was removed
  the same day.

## Mac VoiceOver sessions

Run a Mac VoiceOver speech session on GitHub's hosted runner, not on this machine. On the
Mac a session takes the keyboard focus for its whole length, which stops the owner and every
other session.

- Start a run with `python3 scripts/hosted-run.py voiceover-mac.yml`, not with
  `gh workflow run`, and fetch its transcripts with `gh run download`;
  [VoiceOver testing](doc/voiceover-testing.md#hosted-mac-sessions) has the inputs. A run
  takes about five minutes once it has a runner, and at a fixed pause its transcripts are
  acceptance evidence for the Mac.
- Share the runner. Its five jobs at a time are for every session's runs together
  ([above](#the-hosted-runner)), and the queue has no priorities: a run started to try
  something stands ahead of every run started after it. The script prints what is on a runner
  and what is waiting, as `gh run list --status in_progress` and `gh run list --status queued`
  do, and with no workflow named it starts nothing: look before you start.
- Put the speech sessions you need into one run. Each can have its own window width, text
  size, flow and launch arguments, so step lists that differ in them share a run, a build and
  a runner. Do not start a run for each.
- Keep at most two runs in flight for your branch, and one while any run is waiting for a
  runner. The script starts nothing beyond that. Its `--force` does, and a slow queue is not
  a reason for it.
- Cancel a run of yours as soon as you no longer need it, with `gh run cancel RUN_ID`. Nothing
  else cancels one.
- Ask the owner before any session on this Mac, and only for what a runner cannot do:
  someone listening, or stepping by hand.
- Never run the workflow's preparation commands here (`defaults write`, `launchctl bootout`,
  `displayplacer`). They are for a disposable runner.
- Keep the workflow on `runs-on: xcode-27`. A larger runner is billed even in a public
  repository; `gh api repos/vocaro/EPUBLib/actions/runs/<run>/timing` should report
  `"billable": {}`.

## Branches

Every session's worktree shares one `.git`, and `main` gains commits several times an hour.

- Another session's `git fetch` moves `origin/main` in your worktree. To squash, rebase or
  compare, name the commit your branch was last based on, read once with
  `git merge-base HEAD origin/main`, not the ref. A `git reset --soft origin/main` made after
  the ref had moved staged main's new commits as deletions.
- A pull request that a brief names as open may have merged since the brief was written. Look
  on GitHub before building on its branch, and once it has merged, build on `main`.

## Test corpora

EPUBLib is verified with public material only. The corpora are the W3C's own:
[w3c/epub-tests](https://github.com/w3c/epub-tests), its reading-system conformance tests
(the OCF, package, navigation and content tests among them), and the fixtures of
[w3c/epubcheck](https://github.com/w3c/epubcheck). `scripts/fetch-corpora.sh` fetches both
at pinned commits and prints the variables to set; [testing](doc/testing.md#corpus-runs) says
what each run checks.

- Do not read books from another project's directory on this machine (StudyWright, the
  PDFReflowLib measurements or any other) to test or qualify EPUBLib, and do not record such a
  run in this repository. EPUBLib depends on none of them.
- `EPUBLIB_CORPUS` is a hook for a directory of EPUB files and names no collection. Leave it
  unset unless the owner names the directory for the task in hand.
- The first qualification ([native viewer](doc/native-viewer.md#qualification)) describes a
  run on another project's books. It is history, not a corpus to reproduce.
- When a task needs real books, ask the owner which public collection to use.
