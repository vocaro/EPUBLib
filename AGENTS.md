# Notes for coding agents

## Shared engineering guidance

Before work, run `python3 scripts/eng instructions` to read the common rules and enabled
capabilities, then follow the project-specific instructions below. `engineering.json` locates
the shared `apple-engineering` checkout; set `VOCARO_ENGINEERING_ROOT` for another location.
Before shared device, foreground or runner use, run `python3 scripts/eng policy refresh` and
read this project's current main instructions. Shipping Swift targets do not link the
engineering toolkit, which is public and MIT licensed.

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

The simulator-disposable capability supplies ownership, headless operation and filtered-test
count checks. Use the commands in [testing](doc/testing.md).

- VoiceOver runs in a simulator too. `scripts/run-voiceover-simulator.py` records what it
  reads on simulators of its own, muted, and that record is acceptance evidence for what
  VoiceOver reads on an iPhone and iPad. It is not evidence that VoiceOver activates
  anything: see [Tests are automated](#tests-are-automated) below.
- Do not open a live simulator view or any tool that takes control of a simulator's screen
  (in the Claude desktop app, the iOS Simulator tool) unless the owner has asked to watch.
  Such a tool asks him to approve each device, and a test device is new on every run, so he
  is asked every time.

## Tests are automated

- Before proposing a physical device, say what it would show that a simulator cannot. A check
  said to need a finger usually needs a timing or an input that a UI test can make. Whether a
  swipe scrolls the control strip was put to a finger and answered by a synthetic touch that
  moves at once, with the host recording each touch
  ([reader controls probe](doc/testing.md#reader-controls-probe)).
- For VoiceOver on an iPhone and iPad, a device shows three things a simulator does not:
  VoiceOver activating the item under its cursor, an action performed from the rotor, and a
  page turned in landscape. What VoiceOver reads, in what order, and where its cursor and
  rotor move is settled in the simulator lane. The owner decided on 2026-10-13 that such a
  session is acceptance evidence, so do not ask for a device to hear it again, and do not
  file an issue for a device session that would
  ([VoiceOver testing](doc/testing.md#acceptance-and-evidence)).
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

## Mac VoiceOver sessions

Run a Mac VoiceOver speech session on GitHub's hosted runner, not on this machine. On the
Mac a session takes the keyboard focus for its whole length, which stops the owner and every
other session.

- Start a run with `python3 scripts/hosted-run.py voiceover-mac.yml`, not with
  `gh workflow run`, and fetch its transcripts with `gh run download`;
  [VoiceOver testing](doc/testing.md#hosted-mac-sessions) has the inputs. A run
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

## Where a write-up goes

On 2026-10-13 `doc/` held twelve files named for issues and seven named for releases, and
seven of those issues were closed with no comment on them. The owner had the files moved to
the issues and the release notes, and the same day had the VoiceOver document folded into
[testing](doc/testing.md) and the changelog cut to a sentence an entry.

- Do not add a `doc/issue-N-*.md` or a `doc/verification-X.Y.Z.md`. `doc/` has a document for
  each subject, not one for each issue or release.
- What the library does, why, and where its limits are goes in the document for its subject:
  [architecture](doc/architecture.md), [native viewer](doc/native-viewer.md),
  [reader controls](doc/reader-controls.md) and the others beside them.
- How to run or repeat something goes in [testing](doc/testing.md), VoiceOver sessions
  included. A probe's script and inputs go under
  [Probes and recorded inputs](doc/testing.md#probes-and-recorded-inputs).
- What was run goes on the issue, in a comment: the commit, the machine, the counts, the
  measurements and what was left unverified. A document links to that comment and does not
  repeat it.
- A release's verification goes in its GitHub release notes.
- A changelog entry is one sentence and a link to its issue, at the top of "Unreleased" in
  [CHANGELOG.md](CHANGELOG.md). Where there is no issue, link the pull request. What changed
  in detail is on the issue.

## Labels

On 2026-10-19 the owner had the open issues sorted with labels: by area, by platform, by the
kind of work, and for VoiceOver, which a quarter of them were about. Label an issue when you
file it. `gh label list` gives each label and what it means.

- Give every issue one priority, one `area:` and the kind of work it asks for: `bug`,
  `enhancement`, `documentation`, `question` for a decision, `verify` to run, hear or check
  something, and `investigate` to find a cause before a fix is chosen. An issue about how
  sessions work, or about this file, takes `documentation` and no area.
- Add `voiceover`, `tables` and `accessibility` wherever they apply.
- A `platform:` label names the platform whose reader shows the problem, not the Mac a session
  runs on. Leave it off when both show it.
- `needs: device` marks what only a physical iPhone or iPad can show
  ([above](#tests-are-automated)). Hearing what VoiceOver reads is not one of those.
- When the work changes, change the labels: an investigation that finds its cause becomes a
  `bug`.

## Test corpora

EPUBLib is verified with public material only. The corpora are the W3C's own:
[w3c/epub-tests](https://github.com/w3c/epub-tests), its reading-system conformance tests
(the OCF, package, navigation and content tests among them), and the fixtures of
[w3c/epubcheck](https://github.com/w3c/epubcheck). `scripts/fetch-corpora.sh` fetches both
at pinned commits and prints the variables to set; [testing](doc/testing.md#corpus-runs) says
what each run checks.

The books are two public collections, which the owner made standard corpora on 2026-10-14:
50 from [Project Gutenberg](https://www.gutenberg.org) and 50 from
[Standard Ebooks](https://standardebooks.org), each pinned by SHA-256 in `scripts/corpora`.

- Do not read books from another project's directory on this machine (StudyWright, the
  PDFReflowLib measurements or any other) to test or qualify EPUBLib, and do not record such a
  run in this repository. EPUBLib depends on none of them.
- `EPUBLIB_CORPUS` is a hook for a directory of EPUB files and names no collection. Point it at
  `EPUBLIB_GUTENBERG` or `EPUBLIB_STANDARD_EBOOKS`, or at a directory the owner names for the
  task in hand.
- The first qualification ([native viewer](doc/native-viewer.md#qualification)) describes a
  run on another project's books. It is history, not a corpus to reproduce.
- When a task needs real books, use these two collections.
  - Fetch Project Gutenberg only through `scripts/fetch-corpora.sh`, which keeps to its
    robot-access policy.
  - Never fetch from standardebooks.org, by any route or user agent. Its robots.txt disallows
    agents, so the owner runs `scripts/fetch-standard-ebooks.sh`. Use those books only when
    `scripts/fetch-corpora.sh` verifies them.
  - Ask the owner before adding another collection.
