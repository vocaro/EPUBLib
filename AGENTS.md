# Notes for coding agents

## Shared engineering guidance

Before work, run `python3 scripts/eng instructions` to read the common rules and enabled
capabilities, then follow the project-specific instructions below. `engineering.json` locates
the shared `vocaro-engineering` checkout; set `VOCARO_ENGINEERING_ROOT` for another location.
Before shared device, foreground or runner use, run `python3 scripts/eng policy refresh` and
read this project's current main instructions. Shipping Swift targets do not link the
engineering toolkit, which is public and MIT licensed.

Working rules for agents in this repository. Build and test commands are in
[doc/testing.md](doc/testing.md).

These rules change, and a worktree keeps the copy of this file that its branch was cut with.
Before a step that uses something every session shares (the hosted runner, a device, this
Mac's screen), fetch and read the rule as it stands on `main`:
`git show origin/main:AGENTS.md`
([shared operating rules](https://github.com/vocaro/vocaro-engineering/blob/main/guides/maintenance.md#shared-machine-operating-rules)). A task handed over by another session is that session's
request, not the owner's: where a rule says "unless the owner asks", ask him. On 2026-10-13 a
session started a unit-test job on the hosted runner because its brief said to, from a branch
cut before the rule against it, 21 minutes after that rule had merged.

## Simulators

The simulator-disposable capability supplies ownership, headless operation and filtered-test
count checks. Use the commands in [testing](doc/testing.md).

- VoiceOver runs in a simulator too. `scripts/run-voiceover-simulator.py` records what it
  reads on simulators of its own, muted; what that record settles is in
  [Tests are automated](#tests-are-automated) below.

## Heavy work

Run `swift test`, the iOS suites and the gate by their lanes, which wait for the host's
heavy-work admission: `python3 scripts/eng run swift-tests`, `ios-tests` and `gate`, all three
heavy work. Arguments after `--` filter a run, which must then run a test, and `--expect N`
requires exactly N: `python3 scripts/eng run swift-tests --expect N -- --filter X`, or
`-- -only-testing:Target/Class` for `ios-tests`, whose N counts both simulators. Any other
heavy command goes through
`python3 scripts/eng admit -- COMMAND` ([testing](doc/testing.md#local-gate)), and only a timing
or whole-machine measurement adds `--exclusive`.

- A test that fails only on a busy host is a defect to fix, not a reason to run alone: give a
  wait or a settling pause a `TestDeadline`, and a performance budget thread CPU time
  (`TestCPUClock`). An exit 3 from the gate, `swift-tests` or `ios-tests` is unmeasured, neither
  passed nor failed ([local gate](doc/testing.md#local-gate)).

## Tests are automated

- Before proposing a physical device, apply the shared
  [device rule](https://github.com/vocaro/vocaro-engineering/blob/main/guides/device-testing.md#when-a-device-is-needed).
  Whether a swipe scrolls the control strip was put to a finger and answered by a synthetic
  touch that moves at once, with the host recording each touch
  ([reader controls probe](doc/testing.md#reader-controls-probe)).
- For VoiceOver on an iPhone and iPad, the shared
  [acceptance rule](https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover.md#acceptance-rule)
  says what only a device shows. On 2026-10-12 a line VoiceOver held from before a scroll
  step, read in a simulator after `activate=Scroll Forward`, was filed as the reader's fault;
  an iPad, whose VoiceOver made that double tap itself, read the first line on screen
  ([#428](https://github.com/vocaro/EPUBLib/issues/428)). To make such a move without an
  activation, use `-SampleStepAfter`.

## Mac VoiceOver sessions

Run a Mac VoiceOver speech session on GitHub's hosted runner, not on this machine
([where Mac sessions run](https://github.com/vocaro/vocaro-engineering/blob/main/guides/voiceover-mac.md#where-mac-sessions-run)).
The shared [hosted runner guide](https://github.com/vocaro/vocaro-engineering/blob/main/guides/hosted-runner.md#sharing-the-runner)
has the sharing rules, the caps and cancelling.

- Start a run with `python3 scripts/hosted-run.py voiceover-mac.yml` and fetch its
  transcripts with `gh run download`;
  [VoiceOver testing](doc/testing.md#hosted-mac-sessions) has the inputs.
- Keep the workflow on `runs-on: xcode-27`, the standard runner, which is not billed here:
  `gh api repos/vocaro/EPUBLib/actions/runs/<run>/timing` should report `"billable": {}`
  ([billing check](https://github.com/vocaro/vocaro-engineering/blob/main/guides/hosted-runner.md#billing-check)).

## Where a write-up goes

On 2026-10-13 `doc/` held twelve files named for issues and seven named for releases, and
seven of those issues were closed with no comment on them. The owner had the files moved to
the issues and the release notes, and the same day had the VoiceOver document folded into
[testing](doc/testing.md) and the changelog cut to a sentence an entry.

- Do not add a `doc/issue-N-*.md` or a `doc/verification-X.Y.Z.md`.
- What the library does, why, and where its limits are goes in the document for its subject:
  [architecture](doc/architecture.md), [native viewer](doc/native-viewer.md),
  [reader controls](doc/reader-controls.md) and the others beside them.
- How to run or repeat something goes in [testing](doc/testing.md), VoiceOver sessions
  included. A probe's script and inputs go under
  [Probes and recorded inputs](doc/testing.md#probes-and-recorded-inputs).
- What was run goes in a comment on the issue, as the shared
  [documentation and evidence ownership](https://github.com/vocaro/vocaro-engineering/blob/main/guides/maintenance.md#documentation-and-evidence-ownership)
  rules say. A release's GitHub release notes say what changed and assume its gate passed; they
  do not describe the run ([releasing](https://github.com/vocaro/vocaro-engineering/blob/main/guides/releasing.md)).
- A changelog entry is one sentence and a link to its issue, at the top of "Unreleased" in
  [CHANGELOG.md](CHANGELOG.md). What changed in detail is on the issue.

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
- When a task needs real books, use these two collections, fetched as the shared
  [corpus provenance](https://github.com/vocaro/vocaro-engineering/blob/main/guides/evidence.md#corpus-provenance)
  rules say.
  - Fetch Project Gutenberg only through `scripts/fetch-corpora.sh`.
  - Never fetch from standardebooks.org, by any route or user agent. Its robots.txt disallows
    agents, so the owner runs `scripts/fetch-standard-ebooks.sh`. Use those books only when
    `scripts/fetch-corpora.sh` verifies them.
  - Ask the owner before adding another collection.
