# Testing

## Local gate

Use Xcode 27, a graphical macOS 27 login, the iOS 27 simulator runtime, XcodeGen and Python 3.
Set `DEVELOPER_DIR` when more than one Xcode is installed. From the repository root:

```sh
bash scripts/check-all.sh
```

The gate verifies module boundaries, compares documentation snippets with compiled Swift
sources, runs the Mac tests and the full test suite on dedicated iPhone 17 Pro and iPad Air
13-inch (M4) simulators, and builds both sample app targets. Test devices are created by UUID and
deleted on exit; existing devices are never selected or shut down. Agents working in the
repository drive simulators the same way, headlessly ([notes for agents](../AGENTS.md)). iOS logs live in
`.build/validation/`. `EPUB_SIM_RUNTIME` selects a different installed runtime by identifier.
The Mac tests and the two checks also run on a [hosted runner](#hosted-mac-tests), for a pull request and for `main`.

For narrower checks:

```sh
swift test --filter PublicationSafetyTests
swift test --filter NativeSessionTests
swift test --filter CFI
bash scripts/test-ios.sh
```

A window that mounts a reader for a test calls `keepLightAppearance()` (`ReaderTestWindow.swift`),
so a reader whose style is System opens light on a Mac or simulator in dark appearance, and the
suite gives one result by day and in the evening. A test that needs a dark host sets
`ReaderTestWindow.pageControls.colorScheme`.
`NativeSessionTests.testATestWindowKeepsItsReaderLightUntilTheTestAsksForDark` holds the harness
to that: on the Mac under a dark appearance for its own process, and on iOS, where a test process
cannot make its device dark, by the window's own style. To run a Mac bundle as a machine in light
appearance would, whatever the system setting, pass the argument after `-XCTest`:

```sh
xcrun xctest -XCTest All -NSRequiresAquaSystemAppearance YES .build/debug/EPUBViewingTests.xctest
```

A Mac whose "Show scroll bars" setting is automatic shows overlay scroll bars with a trackpad and
legacy ones while a mouse is attached, and a legacy scroll bar takes its width from continuous
scroll's column ([Layout](native-viewer.md#layout)). A canvas test of where lines sit across that
column says which kind it means with `CanvasHost.setScrollBars` (`ReaderCanvasFixtures.swift`),
which holds the scroll view to it: AppKit gives every scroll view the preferred kind again when
the preference changes, and a process on a Mac with a mouse learns its preference a moment after
it starts. `BoxAlignmentCanvasTests.testShippedStandardEbooksPagesKeepTheirPlaceInContinuousScroll`
runs under both kinds. To run a Mac bundle as a machine with a mouse would, or as one without,
whatever is attached and with no setting changed:

```sh
xcrun xctest -XCTest All -AppleShowScrollBars Always .build/debug/EPUBViewingTests.xctest
xcrun xctest -XCTest All -AppleShowScrollBars WhenScrolling .build/debug/EPUBViewingTests.xctest
```

## Hosted Mac tests

The [Mac unit tests workflow](../.github/workflows/unit-tests-mac.yml) runs `swift test` on
GitHub's hosted `xcode-27` runner, under a stated kind of scroll bar, and then the gate's
module and documentation checks. Nothing else runs on that machine, so a result does not
depend on what other worktrees are building, and the standard runner costs nothing in this
public repository. A run starts for a pull request, which is tested as merged into its base,
for a push to `main`, and by hand:

```sh
gh workflow run unit-tests-mac.yml --ref YOUR_BRANCH
gh workflow run unit-tests-mac.yml --ref YOUR_BRANCH -f scroll_bars=both
gh workflow run unit-tests-mac.yml --ref YOUR_BRANCH -f filter=ReaderCanvasViewTests -f repeat=20
gh run list --workflow unit-tests-mac.yml --limit 3
gh run watch RUN_ID --exit-status
gh run view RUN_ID
```

A change to nothing but `doc/` and Markdown files starts no run. `--ref` chooses the branch
whose workflow file is used, and that branch is tested unless the `ref` input names another.
The inputs, all optional:

- `ref`: a branch, a tag or a full commit SHA to build and test. The steps still come from the
  `--ref` branch, so a commit older than this workflow can be tested, and two commits compared.
- `filter`: the regular expression `swift test --filter` takes, such as `ReaderCanvasViewTests`
  or `CFI`. Empty runs every test. A filter that matches no test fails the run.
- `repeat`: the number of passes, 1 unless given. The tests are built once and run that many
  times, each pass a new process. It is for a test that fails now and then: the runner is the
  quiet machine that tells a test's own timing from a workstation's load.
- `scroll_bars`: the [scroll bars](#local-gate) the tests run under: `legacy` unless given,
  `overlay`, `both` for a job under each, or `automatic` for the runner's own setting.

Each job runs under one kind of scroll bar, which its name gives: `swift test, legacy scroll
bars`. A pull request's run has one job, under legacy ones, the kind that takes its width from
the text. A push to `main` has two, one under each kind, and so has a run by hand with
`scroll_bars=both`. The two are on runners of their own, so the second adds nothing to the
time of a run once it has a runner, and about twelve minutes of a runner to its cost; a pull
request has one job because every run in the repository waits for the same few runners. A
failure that needs overlay scroll bars therefore shows first in the run for `main`, unless a
run by hand asked for both before the merge.

A job gets its kind from the runner's "Show scroll bars" setting, which it writes before it
builds: `defaults write -g AppleShowScrollBars Always` for legacy ones and `WhenScrolling`
for overlay ones. It does that only on GitHub's machine, which is discarded after the job,
and stops on any other; never run it on a workstation, where the arguments
[above](#local-gate) give one process either kind and change no setting. The job then starts
a process that reads the kind as it starts and two seconds later, prints both
(`Scroll bars: legacy as a process starts, legacy two seconds later`) and fails unless both
are the job's kind. The tests say it too: `ScrolledAccessibilityReadTests` prints
`Scroll bars this Mac prefers: legacy` in the log of a pass that runs it.

Left alone, the runner is a Mac on the automatic setting with a pointing device, the virtual
machine's `Virtual USB Digitizer`. A process there reads overlay when it first asks and
legacy a second later, as on a Mac with a mouse. `scroll_bars=automatic` runs the tests so:
the first test of a process to ask meets overlay scroll bars and the tests after it legacy
ones. It is for a failure that needs the change itself. Every hosted run was like that before
the jobs set a kind, and printed `Scroll bars: overlay`, having asked once.

The job fails unless every pass exits 0, and no test is retried: a test that fails there
failed on a machine doing nothing else. `gh run view RUN_ID` lists each failed assertion with
its test, file and line, and a notice with the count of tests. The log has one line for each
pass, `Pass 1 of 1: … tests, … failed, … skipped, … s, swift test exit …`, and after several
passes the failed tests with the number of passes each failed in; the run's summary page has
the same as a table.

After the tests, and whatever their result, a job runs the two checks of the gate that need
no simulator, `scripts/check-modules.py` and `scripts/check-docs.py`, in under ten seconds.
The second compares the documentation's snippets with the sample's shared sources, which the
job's build has compiled by then as the `ReaderSampleSupport` target. A change to
documentation alone starts no run, so a snippet that such a change leaves stale fails the
next run that does start, whoever's it is.

A job has forty minutes. On 2026-10-13 a job took eleven to fifteen minutes, the build two
or three of them and a pass of every test nine to twelve. A pass was 2,534 tests then, 2,483
of XCTest's and 51 of Swift Testing's, with 52 skipped, most of them the opt-in
[corpus runs](#corpus-runs).
Fifty passes of `ReaderCanvasViewTests` took fourteen minutes. A pass is started only if one
as long as the longest so far would end three minutes before the job's limit; otherwise the
passes left are reported as not run, and the job fails. A new run for the same pull request,
or by hand for the same ref, filter, count and scroll bars, cancels one still in progress. A
run for `main` is not cancelled; of the runs waiting behind it only the newest is kept.

A pass that hangs is stopped at a limit of its own, and the passes after it run. The limit is
three times the longest pass that has passed in the job, and five minutes at least; until a
pass has passed it is twenty minutes, about twice a pass of every test. No pass runs beyond
the job's deadline, three minutes before its forty. At the limit the job takes a stack sample
(`sample`, two seconds) of each process `swift test` has started, which is the `xctest`
running a bundle of XCTest's tests or the helper running Swift Testing's, then ends them and
`swift test`. The pass counts as failed, and `gh run view RUN_ID` has an error for it:

```text
Pass 9 of 40 hung in BoxAlignmentCanvasTests.testName: it was stopped after 300 s, at its limit of 300 s
```

The test is the one the pass's log says began and did not end; when the log names none, it is
one whose own frame is in a sample, and with neither the error says `with no test under way`.
The log has the processes and every thread's stack in a group of its own, `Pass 9 of 40,
where it was stopped`, and the list of failed tests has the test with `(hung)` after its
name. The pass's own line and the table say `stopped at its limit of 300 s` where another
pass has its exit status. A pass cut short by the job's deadline is reported as stopped at
the end of the job's time, not as hung. The step sets `NSUnbufferedIO`, so that `swift test`
writes each line as a test makes it and a pass's log ends where the pass did; left alone,
`swift test` holds the newest 16 KB of its output, the line that names a hung test among it.
On 2026-10-13 a healthy pass given a limit of five seconds was sampled, ended and reported
four seconds after it, the log and the sample named the same test, and the pass after it ran
as any other.

A job waits for a runner before it starts. Five jobs run at a time in the repository, these
and the [VoiceOver sessions](voiceover-testing.md#hosted-mac-sessions) together, and the rest
wait. On the evening of 2026-10-12, with about thirty runs an hour, half of 73 jobs started
within ten seconds, 16 waited more than five minutes and the longest eleven; an hour later,
with a run for every pull request as well, the second job of a run waited twelve minutes in
one run and thirty-two in another.

A hosted run differs from the [local gate](#local-gate):

- It runs the Mac tests and the module and documentation checks. The simulator suites and the
  sample builds are the gate's.
- The runner has three processors and 7 GB of memory, and macOS and Xcode are the image's,
  which the job prints before it builds: on 2026-10-12, macOS 27.0.1 (`26A434`) and Xcode 27.0.
- A job's scroll bars are one kind from the start of every process, and a test that says which
  kind it means runs as it does anywhere. A pull request's run has no job under overlay ones,
  and only `scroll_bars=automatic` has a process change from overlay to legacy a moment after
  it starts, as one does on a Mac with a mouse.
- It holds no corpora and no `epubcheck`, so the opt-in runs are skipped.

## Coverage

Parser tests cover EPUB 2/3 structure, navigation, landmarks and page lists, resource access, identity, limits,
duplicate ZIP entries, symlinks, path separators and dot segments beside every scalar that joins
their `Character`, CRC corruption, malformed/deep/wide XML, UTF-16 entities, repeated,
conflicting, absent, remote and differently cased manifest items, references that start at or climb past
the container root or carry a query, padded mimetypes, containers that list another rendition first,
entry names with a colon, archives that other bytes follow, deflated entries whose directory
misstates their sizes, contents entries that do not resolve, named character references and
lower-case doctypes in navigation, control characters in navigation, white space in metadata
values and navigation labels (ASCII whitespace stripped and collapsed however it is written,
white space outside ASCII kept beside other content and a mark after a space kept, a value of
nothing but white space of any kind empty),
cancellation after expansion starts, and exact IDPF/Adobe font deobfuscation vectors. The font
tests check the XOR prefix and the untouched suffix against independently specified keys.

Viewer component tests cover content-document parsing, the CSS cascade and fonts, attributed-text
building and its text map, images, tables, MathML attachments, CFIs and text search, pagination
geometry and the TextKit 2 views. MathML fixtures cover wide display and inline formulas at 17
and 28 points in a 320-point column, their rows as laid out and drawn in both flows, `mglyph`,
elementary math, and readings in French and German content with and without `alttext`. CFI and search tests replay vectors recorded from foliate-js's own
`epubcfi.js` and `search.js` in WebKit before they were removed, so CFIs the WebKit reader
recorded keep naming the same positions. The one exception is deliberate: a CFI into a later
occurrence of a spine item the spine repeats names that occurrence, where foliate-js named the
first ([#108](https://github.com/vocaro/EPUBLib/issues/108)); the spine vectors are held to the
document foliate-js named, not to its index. Live session tests mount a reader in a window, open at
the text start (a `bodymatter` landmark, a guide `text` reference or the first linear section),
navigate between sections, exercise styles and flows, update page controls without changing location/selection/highlights, locate/select passages, restore positions
(including a foliate-written CFI under EPUBLib's bookmark identity, refusing the old tag, and a
restore on `.ready` replacing the text start), report the page-list entries on screen in both
flows after page turns, scrolling, navigation to markers, a restore and a resize, and for a
selection, and close the session. Separate fixtures exercise
encoded filenames and fragments, fixed layout, RTL, vertical writing, and flex and grid alignment
(a centred title page, a Standard Ebooks style epigraph, a grid dedication and layouts left in
block flow, with their expected native geometry), and rows of sized inline blocks (a book of
prose chapters around one whose paragraphs hold runs of marks, each in a box of fixed width;
the runs are checked against where CSS sets them, and the chapter is laid out in pages and in
continuous scroll, four chapters below what the scroll view lays out first, as it is laid out
by itself). The illustrated fixture
has 40 sections and eight incompressible 1024×1024 images; its test enforces an archive size over
20 MiB and verifies that later sections remain navigable. Relayout tests take one mounted
session of a book of labelled SVG figures from wide and light to narrow, large and dark, and
require the images mounted in its text view to be those of a second session opened at that
size and style. They also require replaced and closed text to release its images.

Search-result tests cover a query across three spine documents (counts, spine and document
order, hidden content, section titles, page labels, paragraph and table-cell context, CFIs that
restore and highlight the occurrence), stepping, wrapping and selecting in both flows and in an
RTL book, the current match across page turns, navigation, typography, flow and a remount,
invalidation by clear, a replaced, rejected, superseded or cancelled query, `.locate` and
close, the bounded list, and ten thousand results in one flat section. Control tests cover the
indicator, button and result wording for every state, engines that only highlight, the FIFO
match commands beside page turns, and mount the supplied views in each state: on their own, at
a large accessibility text size and in a navigation toolbar. They do not establish toolbar
overflow, popover or VoiceOver behaviour on a device: SwiftUI builds no accessibility tree for
an in-process query. Set `EPUB_SNAPSHOT_DIR` for `swift test`, or
`TEST_RUNNER_EPUB_SNAPSHOT_DIR` for `scripts/test-ios.sh`, to keep a PNG of each mounted state.
These are layer renders from a test host, not screen captures, so system bar materials and
presentations are absent from them.

Page-input tests cover default and replaced/cleared shortcuts, exact modifiers, duplicate/invalid
bindings, canvas and child focus, selection chords, live iOS recognizer disabling, Mac wheel
pass-through and reset, zero/invalid/asymmetric/overlapping zones, RTL, resizing, fold exclusion,
both reading flows, host commands and iOS VoiceOver page turns with direct input disabled.

Scrolled-read tests hold continuous scroll to the text on screen after the whole book has been
laid out behind the scroll view, as VoiceOver and a UI test's snapshot do when they ask where
every paragraph is: scroll steps, a place scrolled to by hand, and the change back to pages.
The read is a stand-in. A test host loads no text accessibility for an in-process query, so the
tests ask for each paragraph's rectangle through `firstRect(for:)` on UIKit and
`accessibilityFrame(for:)` on AppKit, and require that this laid the whole book out.

Bar tests hold continuous scroll to its place when a bar shows or hides over a reader that runs
under it, which changes the height of the visible area and not the reader's size.
`CanvasHost(…, underBars: true)` puts the canvas under a navigation bar on iOS and under the
title bar of a full-size content view on the Mac, and `setBar(shown:)` hides the one and gives
the window a toolbar on the other. On the Mac nothing lays the canvas out when a toolbar changes
the scroll view's insets ([#162](https://github.com/vocaro/EPUBLib/issues/162)), so the harness
waits for the insets and asks for the layout. The session test uses the public reader with
`ignoresSafeArea()`: under a `NavigationStack` whose bar it hides on iOS, and on the Mac in a
window whose toolbar it shows and hides, each followed by a change of appearance, which lays the
reader out. The bars are the system's own, in a test host; nothing is looked at on a screen.
Each window's toolbar has an identifier of its own: toolbars that share one share their
visibility across the windows of a process, so hiding one hides the next test's.

Heading tests cover which characters the builder marks as a heading and at what level: `h1`
to `h6`, `role="heading"` with and without `aria-level`, a role that takes a heading away, a
heading run in with its paragraph, hidden headings and hidden words inside a shown one. They
hold the mark to changing nothing else: one chapter is built with its headings marked and
again with each told to be presentation only, and the two must have the same characters, text
map, anchors and other attributes, and the same lines in the same places on every page at two
sizes. View tests read what each platform gives an assistive technology. On UIKit: one element
for a heading over all its lines, with its trait and level, the part of it a page shows, the
one element it keeps in continuous scroll with its first line above the screen, and the
Headings rotor moving through a page and on through the book in both flows. On AppKit: the
level in a column's rich text, and the rotor's headings asked for as VoiceOver was seen to
ask. None of them drives VoiceOver; the [VoiceOver testing process](voiceover-testing.md) has
what it said.

Link tests on AppKit (`LinkAccessibilityTests`) read what a column and the scroll view give
an assistive technology for a link: one element for a link whose font changes inside it, with
its words, its place and a press that reports the link; the names of links that are pictures,
hidden labels and formulas, and never U+FFFC; a link element as the attachment of each
picture or label in a link, and none over a link's words; a hidden label's place, which has a
size though the label has none; a link cut at a page's end and continued on the next page;
the links on screen in continuous scroll; and a text view with no canvas, as a note's
popover has, left with AppKit's own. What VoiceOver says of each is recorded with the
[VoiceOver testing process](voiceover-testing.md#links).

Highlight paint tests read the pixels the mounted reader's views last drew: none in the
highlight's color before a search, the matches after it, and none again after Clear Search,
with no reflow between. They cover both flows, one- and two-column spreads, dark appearance,
table cells, a highlight-only search and host highlights added and removed in place.
`ReaderPaintRecorder` copies each `draw(_:)` the system makes of a view under the canvas into a
bitmap kept for that view and composes those as the views are arranged. Rendering the view
does not serve: on Mac `cacheDisplay(in:to:)` and `CALayer.render(in:)` draw afresh, showing
what the reader would paint now and never a surface nothing invalidated, which is what stays
on screen; they counted no highlight pixels while the cleared matches were still painted.
`drawHierarchy(in:afterScreenUpdates:)`, which reads what UIKit composed, has no render server
in the simulator's test host. On Mac the tests turn off AppKit's text checking in the reader's
text views; it redraws them about a second after their text is set, which could repaint a
stale surface before it was read. Set `EPUBLIB_PAINT_DIR` to a directory to keep each step's
picture and counts.

Control view tests read the platform controls SwiftUI builds for the supplied controls: the
Mac reading-mode segments' accessible names, values and actions, the picker's selection and
disabled state on both platforms, the search field's editing, submission and survival of its
pane beside a real reader, and that the field stands outside the reader's page keys. SwiftUI
draws the supplied buttons and menus itself and exposes them to no in-process test; their
names, capabilities and disabled states are checked in the model they read.

Coverage-gap suites (`…CoverageTests`, `SpecConformance…`, `EPUBCheck…`) come from a review
of the package by source area, against the EPUB Reading Systems 3.3 requirements one by one
and against EPUBCheck's scenario inventory. Their fixtures are original and built in code. A
test that exposes an open defect is marked `XCTExpectFailure` (or `withKnownIssue`) with its
issue's URL, and fails once the defect is fixed: remove the marker with the fix. Ratio-timed
cost tests and tests that fail on one platform only are marked non-strictly or for that
platform. A test whose input kills the test process is disabled by name (`disabled_test…`)
with its issue above it. A test of input that TextKit might never finish laying out runs the
layout under `BoundedLayout` (`BoxLayoutTerminationCoverageTests`), which stops the reader's
text container answering after a set number of calls, so the test fails instead of hanging
the suite. Three [corpus runs](#corpus-runs) are opt-in: `EPUBLIB_W3C_EPUB_TESTS` (the `tests`
directory of w3c/epub-tests) holds each W3C reading-system test to an expected outcome,
`EPUBLIB_EPUBCHECK_FIXTURES` (`src/test/resources` of w3c/epubcheck) takes every EPUBCheck
fixture through opening, text extraction and a native build, and `EPUBLIB_EPUBCHECK_CLI` (the
`epubcheck` executable, macOS only) validates a matrix of written books.
`EPUBLIB_W3C_EPUB_TESTS_REPORT` (a file) and `EPUBLIB_EPUBCHECK_REPORT` (a directory) keep
their per-fixture results. Those runs fail today on the same open issues.

These are deterministic regression fixtures, not an EPUB conformance certification, a comprehensive
typographic review, an accessibility audit or a memory budget measurement. They do not establish
VoiceOver speech or focus order, keyboard-only traversal, native toolbar overflow or iPhone Duo
layouts ([#51](https://github.com/vocaro/EPUBLib/issues/51)), which need live sessions.
The suite runs on OS 27; older platforms are outside the package's deployment targets. Simulator
coverage does not substitute for hardware performance and accessibility testing.

For real VoiceOver sessions, use the [VoiceOver testing process](voiceover-testing.md) and
the isolated `Examples/VoiceOverVerification` reader. Its diagnostic speech probe is outside
the local gate because it takes control of the user interface and changes VoiceOver state.
`scripts/run-voiceover-simulator.py` runs that probe on simulators of its own, with no window
and no sound, and takes over nothing: it records what a
[simulator's VoiceOver](voiceover-testing.md#simulators) reads, in order and after a page
turn. That VoiceOver activates nothing it reads, so page actions, the rotor and acceptance
stay with the Mac and physical devices.

## Corpus runs

The corpora are public and the W3C's own: [w3c/epub-tests](https://github.com/w3c/epub-tests),
the reading-system conformance tests (OCF, package document, navigation, content documents,
layout), and the fixtures of [w3c/epubcheck](https://github.com/w3c/epubcheck), valid and
invalid. Neither is kept in the repository. Fetch them once and set the variables:

```sh
eval "$(bash scripts/fetch-corpora.sh)"
swift test --filter "SpecConformanceW3CCorpus|EPUBCheckCorpus|EPUBCheckWriterValidationTests"
```

The script fetches each corpus at a pinned commit into `~/Library/Caches/EPUBLib/corpora`
(`EPUBLIB_CORPORA_DIR` names another place), which every worktree shares, and prints
`EPUBLIB_W3C_EPUB_TESTS`, `EPUBLIB_EPUBCHECK_FIXTURES` and, when `epubcheck` is installed,
`EPUBLIB_EPUBCHECK_CLI`. The expected outcome of each W3C test is in
`Tests/EPUBTestSupport/SpecConformanceCorpus.swift`; a new pin goes in the script together
with that table.

`NativeCorpusQualificationTests` builds every book under `EPUBLIB_CORPUS`, a list of
directories of EPUB files. The variable names no collection and is not part of verifying a
change. The [first qualification](native-viewer.md#qualification) ran it on books that belong
to another project; EPUBLib does not depend on that project or its files, and they are not to
be used to test it.

## Adapter contract tests

The internal **EPUBViewingTestSupport** target exercises adapter contracts with
`EPUBEngineContract.verify`. It uses no XCTest or renderer types, so adapters can call it from
XCTest, Swift Testing or another async test runner. Provide a validated two-section publication,
two distinct encoded resource hrefs, a phrase present in the first section, and a `mount` closure
that places the session in a visible test window and returns a cleanup closure retaining that window.
`NativeSessionTests.testReusableEngineContract` is a complete call-site example.

The verifier checks:

- A pre-cancelled command throws `CancellationError`.
- The mounted session emits `.ready` exactly once.
- Advertised commands can be submitted; unsupported commands return the matching capability error.
- Href navigation changes sections and bookmark restoration returns to the saved section.
- Locations carry the publication identity and a valid engine-tagged bookmark when supported.
- Foreign publication, engine and bookmark format identities are rejected.
- An engine with `.searchResults` lists the phrase's results before reporting completion, with
  indices in order and the publication's identity; steps, wraps and selects as
  `EPUBSearchResults.steppedIndex(forward:)` says; mirrors the list in `readerState` when it has
  one; refuses an unlisted result; and withdraws the list on clear, after which a kept result is
  refused and no step has any effect. An engine without it refuses the three result commands
  with `.unsupported(.searchResults)` and publishes no results.
- Close is idempotent; closed commands fail and later callbacks are suppressed.

A minimal SwiftUI test engine runs the same checks with no renderer at all, as an engine with no
search, one that only highlights and one that lists results. Deliberately broken
engines demonstrate that missing/duplicate readiness, ignored cancellation, incompatible restoration,
late callbacks, results published after completion, steps that do not wrap, stale results that
still navigate and results kept after a clear fail the verifier. Adapter-specific tests must additionally check actual rendering,
selection gestures, precise bookmark semantics and resource release. A bounded quiet period after
close detects queued callbacks; it cannot prove that an engine will never emit a much later event.

The contract verifier requires at least two distinct section hrefs when the engine advertises href
navigation. It permits a navigation to the already-current section to be a no-op. `send` acknowledges
submission, so fidelity checks must wait for events or inspect the mounted renderer themselves.
