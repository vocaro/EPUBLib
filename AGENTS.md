# Notes for coding agents

Working rules for agents in this repository. Build and test commands are in
[doc/testing.md](doc/testing.md).

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
  reads on simulators of its own, muted; [VoiceOver testing](doc/voiceover-testing.md#simulators)
  says what that does and does not establish.
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
- His approval of a run on his device covers installing and launching there. It is not an
  offer to operate it.
- Record what automation cannot reach as not verified, and leave it to him.

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

- Start one with `gh workflow run voiceover-mac.yml` and fetch its transcript with
  `gh run download`; [VoiceOver testing](doc/voiceover-testing.md#hosted-mac-sessions) has the
  inputs. It takes about five minutes, several can run at once, and at a fixed pause its
  transcript is acceptance evidence for the Mac.
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
