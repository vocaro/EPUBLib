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
- Do not open a live simulator view or any tool that takes control of a simulator's screen
  (in the Claude desktop app, the iOS Simulator tool) unless the owner has asked to watch.
  Such a tool asks him to approve each device, and a test device is new on every run, so he
  is asked every time.

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
- The earlier qualification records ([native viewer](doc/native-viewer.md#qualification),
  [flex and grid](doc/issue-20-flex-grid-alignment.md)) describe runs on another project's
  books. They are history, not a corpus to reproduce.
- When a task needs real books, ask the owner which public collection to use.
