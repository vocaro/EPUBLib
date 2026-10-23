# Testing

## Local gate

Use Xcode 27, a graphical macOS 27 login, the iOS 27 simulator runtime, XcodeGen and Python 3.
Set `DEVELOPER_DIR` when more than one Xcode is installed. From the repository root:

```sh
python3 scripts/eng run gate
```

`gate` is the `exclusive` lane in `engineering.json` that runs `scripts/check-all.sh`, which
takes no arguments. The gate checks the hosted-run and VoiceOver session scripts, verifies
module boundaries, compares documentation snippets with compiled Swift sources, holds the
license texts EPUBCore ships to their projects' files and to the
[third-party notices](third-party-notices.md) ([license texts](#license-texts)), runs the Mac
tests and the full test suite on dedicated iPhone 17 Pro and iPad Air 13-inch (M4) simulators,
reads the objects those runs compiled, StaticSVG's among them, and the resvg library
StaticSVG's release supplies, for any API that an app would have to
declare in a privacy manifest ([integration](integration.md#privacy-manifest)), and builds the
VoiceOver verification host for Mac and iOS. Test devices are created by UUID and
deleted on exit; existing devices are never selected or shut down. Agents working in the
repository drive simulators the same way, headlessly ([notes for agents](../AGENTS.md)). iOS logs live in
`.build/validation/`. `EPUB_SIM_RUNTIME` selects a different installed runtime by identifier.
None of this runs on a hosted runner, and nothing starts by itself for a pull request or for
`main`: GitHub's runner is for [Mac VoiceOver sessions](#hosted-mac-sessions)
only ([hosted Mac runner](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#purpose-and-limits)).

The script checks use Python's standard `unittest` library and run independently with:

```sh
python3 -m unittest discover -s scripts/tests -v
```

They run copies of the scripts in temporary directories with fake tool commands,
or stub application and probe calls in process; the simulator revision and toolkit location
checks use real local Git repositories and worktrees in those temporary directories. They need
no network, GitHub login, build or running app, and never start VoiceOver or a hosted job. They
cover queue refusals and dispatch arguments, per-session settings and Safari restrictions,
session deadlines and reports, the list state used when restoring VoiceOver
([#433](https://github.com/vocaro/EPUBLib/issues/433)), simulator build revisions
([#504](https://github.com/vocaro/EPUBLib/issues/504)), where the scripts find the shared
toolkit ([#701](https://github.com/vocaro/EPUBLib/issues/701)), which symbols the privacy
manifest check counts as an API to declare
([#685](https://github.com/vocaro/EPUBLib/issues/685)), and which license copies the license
check refuses ([#699](https://github.com/vocaro/EPUBLib/issues/699)).
They do not establish what VoiceOver reads or does; that uses the speech lanes below.

These checks and `scripts/eng` need the [shared engineering toolkit](shared-engineering.md), a
clone of vocaro/apple-engineering at `toolkit.path` in `engineering.json`, `../apple-engineering`.
From a session's worktree the scripts also look beside the repository's main checkout
([locating the toolkit from a worktree](https://github.com/vocaro/apple-engineering/blob/main/guides/adoption.md#locating-the-toolkit-from-a-worktree)),
so a session that shares the main checkout's clone sets nothing
([#701](https://github.com/vocaro/EPUBLib/issues/701)). `VOCARO_ENGINEERING_ROOT` names
another clone and comes first; the checks give the copies of the scripts they run the clone
they find.

Run one gate at a time on this shared Mac, with its Mac and iOS suites one after the other.
The `gate` lane waits for the host's
[heavy-work admission](https://github.com/vocaro/apple-engineering/blob/main/guides/shared-host.md#heavy-work-admission)
to have no other heavy work running and holds every slot while it runs. Keep build and test
worker counts bounded. Admission sees only admitted work, so look for every run on the host
first, as that section describes: on 2026-10-20 a check of the worktrees alone missed another
session's Mac suite.
EPUBLib's runs are listed by
`ps -Ao args | grep -E '[E]PUBLib.*\.xctest|[c]heck-all\.sh|[t]est-ios\.sh'`.
Synchronous performance assertions use thread CPU time and asynchronous readiness waits
wall-clock deadlines; record host activity beside the results as context, as
[CPU, scheduling and core-wait time](https://github.com/vocaro/apple-engineering/blob/main/guides/measurement.md#cpu-scheduling-and-core-wait-time)
describes. The idle-CPU recipe [reported in #62](https://github.com/vocaro/EPUBLib/issues/62#issuecomment-6155249383)
is a heuristic from one session, not a gate requirement or an acceptance cutoff.

When several branches are ready at once, one gate can serve them all, as
[concurrent Git integration](https://github.com/vocaro/apple-engineering/blob/main/guides/maintenance.md#concurrent-git-integration)
describes, and a filtered Mac run does not stand in for the iOS suites. On 2026-10-21 such a
gate over ten branches, each of whose own Mac runs had passed, found three iOS-only failures
in two of them: a test helper that drew images upside down under UIKit
([#664](https://github.com/vocaro/EPUBLib/pull/664#issuecomment-6309444868)), and a frozen iOS
layout expectation that a change to float grouping moved
([#666](https://github.com/vocaro/EPUBLib/pull/666)). Before opening a pull request that changes
drawing, layout or pagination, run its classes on a simulator as well.

The Mac suites need the screen unlocked and the display awake
([lock screen and display sleep](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#lock-screen-and-display-sleep)
has the checks). While the display sleeps,
`ScrolledAccessibilityReadTests.testWheelAndTrackpadAfterAReadKeepTheTextOnScreen` times out
waiting for a wheel event to move the text. On 2026-10-14 it failed that way on branches that
had passed it an hour before, and on `main`, until the owner unlocked the Mac
([#561](https://github.com/vocaro/EPUBLib/pull/561#issuecomment-6179173544)). Look before a
gate and before blaming a change for that failure.

`scripts/test-ios.sh` runs its devices as
[disposable simulators](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#disposable-simulators).
It reports `Passed` or `Failed` for each device, continues to the second after a creation, boot
or test failure, and exits nonzero if either failed. A passed device reports the tests it ran:
XCTest's total for each test bundle, which `xcodebuild` runs one at a time, and Swift Testing's
for each run. A device that ran none fails. Arguments go to each device's `xcodebuild test`.
Each first boot has a 600-second limit (`EPUB_SIM_BOOT_TIMEOUT` overrides it with a positive
number of seconds). The device and last
boot stage, including any migration plugin, are retained in
`.build/validation/<device-kind>-boot.log`, the identifier creation printed in
`<device-kind>-create.log`, and the test log in `<device-kind>.log`. Destination discovery gets
600 seconds.
The failure, timeout and interruption paths can be checked without creating a simulator:
`python3 scripts/test-test-ios.py` substitutes fake `xcrun` and `xcodebuild` commands in a
fresh temporary directory and checks that every created device is deleted.

The Mac and iOS suites are `heavy` lanes of their own, `swift-tests` and `ios-tests`, and the
narrower checks are runs of them. Arguments after `--` go to the lane's command: a `swift test`
filter, or `xcodebuild test` options such as `-only-testing:` for each simulator.

```sh
python3 scripts/eng run swift-tests
python3 scripts/eng run swift-tests -- --filter PublicationSafetyTests
python3 scripts/eng run swift-tests -- --filter NativeSessionTests
python3 scripts/eng run swift-tests -- --filter CFI
python3 scripts/eng run ios-tests
python3 scripts/eng run ios-tests -- -only-testing:EPUBViewingTests/NativeSessionTests
```

A lane fails a run that reports fewer tests than its `minimumTests`, a whole run's count. A run
with arguments must run at least one, and `--expect N` requires exactly N, so that a filter
shows it selected the tests it was meant to:
`python3 scripts/eng run swift-tests --expect N -- --filter X`. `eng` adds up what the log
reports: each test bundle's total, each Swift Testing run and each unittest run. A filtered
`ios-tests` run counts both simulators, so 12 tests on each is `--expect 24`. The floors are
counts that a toolkit older than apple-engineering 18c01d4, which took the largest single count
in place of the sum, accepts as well. Any other heavy command in this
document, such as a probe's `swift test`, `xcodebuild` or `xcrun xctest`, goes through
`python3 scripts/eng admit -- COMMAND`, with `--exclusive` for a whole-machine measurement. The
plain commands are for a contributor's own machine.

On the Mac, the harness calls `makeMacTestWindow`, which runs `prepareMacTestApplication`
before constructing an `NSWindow` or starting `NSApplication`. It puts
`ApplePersistenceIgnoreState=YES` in the volatile `NSArgumentDomain`, so no saved window is
restored
([offscreen AppKit hosting](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#offscreen-appkit-hosting)).
The opt-in `ReaderTestWindowTests.testKilledWindowProcessProbe` mounts a window and kills
only its own test process with SIGKILL, so a normal pass can check that it restarts without
a restoration alert. After building the tests, run the probe by itself (a nonzero exit is
expected), then run the ordinary window tests under both launch paths without a restoration
argument:

```sh
EPUBLIB_TEST_KILL_WINDOW_PROCESS=YES xcrun xctest -XCTest EPUBViewingTests.ReaderTestWindowTests/testKilledWindowProcessProbe .build/debug/EPUBViewingTests.xctest
swift test --skip-build --filter ReaderTestWindowTests
xcrun xctest -XCTest EPUBViewingTests.ReaderTestWindowTests .build/debug/EPUBViewingTests.xctest
```

The canvas harness waits up to ten seconds for the current selection report or a new visible
range matching the move the test made. A previous non-nil selection does not satisfy that wait.
The delayed-observer regression keeps such a previous report and delays delivery of the next
one by 450 ms, longer than the former 300 ms sleep. The session harness also waits until the
book's completion callback has been announced: storing its last section makes `isComplete`
true before that callback reloads the mounted continuous-scroll view.

Qualification on 2026-10-13, based on `main` at `24400a9e0203f9e325ca98f5917e1d2e17955189`:
all five cases named in [#268](https://github.com/vocaro/EPUBLib/issues/268) passed five times
without added CPU workers and five times with two owned CPU workers (50 executions). This
capped contention did not reproduce the historical failure or establish load as its cause.
With the matching report waits, those five and the delayed-observer case passed ten times
without added workers and five times with two workers (90 executions). The workers were
stopped after the run. The focused Swift run passed 202 cases with one intentionally skipped
kill probe, and the killed-window restart above passed four cases with one skip under each
launch path, without an external restoration argument. The simulator-free iOS gate checks
cover both-device reporting, creation/boot/test failure, stalled boot, and interruption during
creation and testing, including a creation that ignores TERM. Real simulator qualification is
part of the local gate; fake-tool checks do not establish simulator boot or iOS test success.

A window that mounts a reader for a test calls `keepLightAppearance()` (`ReaderTestWindow.swift`),
so a reader whose style is System opens light on a Mac or simulator in dark appearance, and the
suite gives one result by day and in the evening. A test that needs a dark host sets
`ReaderTestWindow.pageControls.colorScheme`.
`NativeSessionTests.testATestWindowKeepsItsReaderLightUntilTheTestAsksForDark` holds the harness
to that: on the Mac under a dark appearance for its own process, and on iOS, where a test process
cannot make its device dark, by the window's own style. The window keeps Increase Contrast and
Bold Text off in the same way, whatever the machine's settings, and a test turns them on with
`pageControls.increasesContrast` and `pageControls.boldText`; with
`pageControls.accessibilityFollowsWindow` the reader takes them from the window instead, as an
app's does, which on iPhone and iPad a test sets with the window's `traitOverrides`
(`ReaderThemeTests.testTheWindowsTraitsReachTheReader`). To run a Mac bundle as a machine in light
appearance would, whatever the system setting, pass the argument after `-XCTest`:

```sh
xcrun xctest -XCTest All -NSRequiresAquaSystemAppearance YES .build/debug/EPUBViewingTests.xctest
```

A legacy scroll bar takes its width from continuous scroll's column
([Layout](native-viewer.md#layout)), and which kind a Mac shows depends on its setting and on
what is attached
([pinned render settings](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#pinned-render-settings)).
A canvas test of where lines sit across that column says which kind it means with
`CanvasHost.setScrollBars` (`ReaderCanvasFixtures.swift`), which holds the scroll view to it.
`BoxAlignmentCanvasTests.testShippedStandardEbooksPagesKeepTheirPlaceInContinuousScroll`
runs under both kinds. To run a Mac bundle as a machine with a mouse would, or as one without,
whatever is attached and with no setting changed:

```sh
xcrun xctest -XCTest All -AppleShowScrollBars Always .build/debug/EPUBViewingTests.xctest
xcrun xctest -XCTest All -AppleShowScrollBars WhenScrolling .build/debug/EPUBViewingTests.xctest
```

A Mac test takes a window through a live resize, as a drag of its edge does, with
`setFrame(_:display:animate:)`, which the hosting guide above describes, and AppKit's text
view does its own work when a resize ends
([Layout](native-viewer.md#layout), "Continuous scroll"). `ScrolledLiveResizeTests` has the
helper, with a view that counts the live-resize calls, and skips where AppKit resizes without
one.

A `swift test` that hangs can be made to say where:
[hung and buffered test runs](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#hung-and-buffered-test-runs)
has the unbuffered run and the stack sample. On 2026-10-12, with a test made to wait twenty
seconds, a plain run's log was empty ten seconds in, the log of a run with `NSUnbufferedIO=YES`
ended at that test's `started` line, and the sample had the test's frame on the main thread.

### License texts

`scripts/check-licenses.py` reads each dependency's files from its checkout in `.build/checkouts`
at the revision `Package.resolved` pins, so it runs after `swift build`. It compares Git blob
hashes, byte for byte, and names each copy in `Sources/EPUBCore/Licenses` that differs, is missing
or copies no pinned file, a folder the [third-party notices](third-party-notices.md) do not name,
and a version there that is not the pin. When a pin moves, copy the new release's files over the
old ones under the names the notices give, and change the version there.
`PackageLicenseTests` reads every text through `EPUBLicense.all()` on the Mac and on both
simulators.

To see the texts as an app gets them, build one that depends on the package by revision, from a
pushed commit, as the
[distribution checks](https://github.com/vocaro/apple-engineering/blob/main/guides/packaging.md#swift-package-distribution-checks)
describe. An XcodeGen project with a macOS and an iOS `application` target, each linking
`EPUBViewing` from `https://github.com/vocaro/EPUBLib.git` at `revision:`, whose `main.swift`
prints what `EPUBLicense.all()` gives and the bytes of each `text()`, is enough. Build both with
`CODE_SIGNING_ALLOWED=NO` through `python3 scripts/eng admit --`, run the Mac app's executable,
compare `EPUBLib_EPUBCore.bundle/Licenses` in each app with `Sources/EPUBCore/Licenses`
(`diff -r`), and check that ZIPFoundation's bundle still holds its `PrivacyInfo.xcprivacy`.

## Coverage

Parser tests cover EPUB 2/3 structure, navigation, landmarks and page lists, resource access, identity
across copies of a book (#679), books unpacked into folders with their links, pipes and limits (#680), limits,
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
elementary math with finite rules, positioned carries and all ten division styles, and generated readings in all five supported languages with regional and English fallback. Authored `alttext` is preserved. Inline canvas checks cover drawn rows, continuation pages, stable source offsets and resizing. CFI and search tests replay vectors recorded from foliate-js's own
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
a large accessibility text size and in a navigation toolbar. They hold the announcement after a
step or a chosen result, and that a presentation covers the reader only in a window of compact
width, which is read from a view the test mounts rather than by choosing a row. They do not
establish toolbar overflow, popover or VoiceOver behaviour on a device, and a row cannot be
activated in process either
([an in-process query does not see what VoiceOver is given](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#an-in-process-query-does-not-see-what-voiceover-is-given)).
The canvas test of pages kept under a keyboard posts UIKit's keyboard notification itself and
makes the canvas shorter, as a host's stack does
([#49](https://github.com/vocaro/EPUBLib/issues/49#issuecomment-6279333375)). Set `EPUB_SNAPSHOT_DIR` for `swift test`, or
`TEST_RUNNER_EPUB_SNAPSHOT_DIR` for `scripts/test-ios.sh`, to keep a PNG of each mounted state.
These are layer renders from a test host, not screen captures
([window renders and system screenshots](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#window-renders-and-system-screenshots)),
so system bar materials and presentations are absent from them.

Page-input tests cover default and replaced/cleared shortcuts, exact modifiers, duplicate/invalid
bindings, canvas and child focus, selection chords, live iOS recognizer disabling, Mac wheel
pass-through and reset, zero/invalid/asymmetric/overlapping zones, RTL, resizing, fold exclusion,
both reading flows, host commands and iOS VoiceOver page turns with direct input disabled.

Scrolled-read tests hold continuous scroll to the text on screen after the whole book has been
laid out behind the scroll view, as VoiceOver and a UI test's snapshot do when they ask where
every paragraph is
([accessibility observation can change layout](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#accessibility-observation-can-change-layout)):
scroll steps, a place scrolled to by hand, and the change back to pages. The read is a
stand-in for one an in-process query cannot make (above): the tests ask for each paragraph's
rectangle through `firstRect(for:)` on UIKit and `accessibilityFrame(for:)` on AppKit, and
require that this laid the whole book out.

Bar tests hold continuous scroll to its place when a bar shows or hides over a reader that runs
under it, which changes the height of the visible area and not the reader's size.
`CanvasHost(…, underBars: true)` puts the canvas under a navigation bar on iOS and under the
title bar of a full-size content view on the Mac, and `setBar(shown:)` hides the one and gives
the window a toolbar on the other. On the Mac the harness waits for the canvas's safe area to
follow the toolbar and lays out as display cycles do; it asks for no layout of its own, so a
reader that is not laid out for its new safe area fails
([#162](https://github.com/vocaro/EPUBLib/issues/162)). The session test uses the public reader with
`ignoresSafeArea()`: under a `NavigationStack` whose bar it hides on iOS, and on the Mac in a
window whose toolbar it shows and hides. `ViewCoverageCanvasTests` holds pages and continuous
scroll on the Mac to a toolbar shown, hidden and shown again over a canvas that fills a
full-size content view, and `ReaderImageInspectionTests` holds the image inspector's controls
to it. `BoxAlignmentCanvasTests` also hides the toolbar with the view at the end of the book,
where AppKit cannot move the view by the whole change in the inset. The bars are the system's
own, in a test host; nothing is looked at on a screen.
Each window's toolbar has an identifier of its own, for the reasons
[offscreen AppKit hosting](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#offscreen-appkit-hosting)
gives.

Table reading-order tests hold a table on iPhone and iPad to one accessibility element for each
row, between the lines around it and in both flows: text with its cells' words, the actions of
its own cells, a row continued across pages by each page's own words, a row of pictures as an
image without a name, and an empty row or a row of decoration as nothing unless the page holds
nothing else. They also hold every view the reader mounts inside a text
view that lists its lines to being hidden from assistive technology. That VoiceOver reads what
such a view offers before the lines of a page column is known only from
[speech sessions](#voiceover-testing); no in-process query shows it.

Table header tests hold the model to HTML's rule for which cells head a column and a row,
with and without `scope`, in `thead` and for cells that span, and to the rule for which tables
are data: each mark that makes one so, a `role` that decides either way, twenty rows or
cells, the ways of ruling a grid, and backgrounds, which do not count in either appearance.
Data table tests read, on iPhone and iPad and in both flows, what VoiceOver is given for such
a table, through the protocols it uses: one container for the table between the lines around
it, a cell element for every cell with its rows and columns, the cell for each slot, the
header cells of a row and a column, frames where the cells are drawn, and each cell's actions,
performed. They cover cells that span, a table split across pages with its header row on
another page, a row taller than a page, cells of pictures, and a table marked as layout. Two
stand in for VoiceOver's cursor in continuous scroll, as the scrolled-lines tests do: one
reads on through a table of seventy rows and back, finding each next stop as UIKit does, in
the cell's container and then in the text view, and then moves down a column row by row; the
other rests the cursor in a table and scrolls away. Neither drives VoiceOver.
Table select action tests perform Select Table Text on a row and Select Cell Text on a cell,
in both flows, and hold each to the same: the reader reports the words, the canvas as drawn
shows them selected, the item has the selected trait, VoiceOver is told that the item
changed, and the item then offers Deselect, Copy and the host's selection action, each
performed. The drawing is read from the canvas's pixels, counting those of the cell's ground
that changed: the cell draws a selected word's ink over the row's own, which changes pixels
at the letters' edges with no selection shown, and passed a count of any pixel. What the
reader posts to an assistive technology is taken from the canvas
(`ReaderCanvasView.postToAccessibility`) instead of posted. A third test selects a passage
through two cells in code, as a located passage is, and reads each cell's share from the
pixels, and a fourth holds a cell to painting no selection of its own while its view is first
responder, when UIKit draws it, and to painting it again when the view gives that up. That
VoiceOver reads the item again and takes its new actions when told is known only from
[speech sessions](#voiceover-testing) on a device: the tests passed before the reader told
it anything, and an iPad's rotor still offered Select alone.
Table scrolled-cell tests hold continuous scroll, on Mac, iPhone and iPad, to a text view on
every cell of every row the screen shows after a move the reader makes itself, with nobody
scrolling after it: a book opened at a chapter, a contents entry, a link to a cell from
before it and from after it, steps of a page, and new sizes. They take what the reader
mounted before they ask the layout anything, find each row on screen from the reader's own
read of the visible lines, and require the row's cells inside the row as drawn, a second look
that finds the same cells in the same places and, on iPhone and iPad, each cell's item
offering its action. One test makes a scroll that is not the reader's, a screen at once as
the system makes for an assistive technology or a drag of the scroll bar, and holds the rows
it reaches to the same once the reader has read where the view stands. A last test holds a
highlight set before the reader goes to its row, and a selection in the row a step back
leaves last on screen, to being on their cells. The book
has a table of 120 rows, taller than any screen here: the rows that went without cells were
those TextKit had not laid out when the scroll view told of the move, the lowest on screen,
and a test whose table stood whole at the top of its chapter passed without the change that
it was written for ([#472](https://github.com/vocaro/EPUBLib/issues/472)). Each kind of move
is made in a reader that has looked at nothing else, since a check lays text out past the
screen and the next move then finds its rows. Without the change the contents entry, the
first step of a page, the system's scroll and the highlight fail on iPhone and iPad, and on
Mac all of those but the highlight; a new size, a link to a cell and the selection
hold either way, the first because a new size ends in a layout pass that looks for the rows
again, the others because the reader's last scroll to a cell is a small one made after the
text is laid out. The test of a book opened at a chapter depends on whether every chapter is
built when the commands arrive, and fails without the change in most runs, not all.

Accessibility action tests hold each item of a page and of a screen on iPhone and iPad to
offering its own actions and no more: a line, a heading and a link their page turns in pages
and nothing in continuous scroll, an image also its own inspection, and a table row also what
its cells can do. They read an item's actions and then those of every view above it, as
VoiceOver gathers them, in a reader mounted in the public SwiftUI view, and perform each one.
They give the text view an action through its setter and hold it to passing none on while it
lists lines, and a note's text view to passing it on. A line's page turn is held to turning
the page while text is selected and to failing at either end of the book. SwiftUI builds no
accessibility elements in a test host, so that the reader view names no page action on iPhone
and iPad is known only from speech sessions too.

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
ask. None of them drives VoiceOver; the [VoiceOver testing process](#voiceover-testing) has
what it said.

Page-turn tests on UIKit (`PageTurnAccessibilityTests`) put an assistive technology's cursor
on a line of a page as UIKit tells the reader of it, by the line's own callback and the
focus notification, and read what the canvas posts when the page is shown anew
(`ReaderCanvasView.postAccessibilityNotification`). A page turned from a line posts one
layout change with the element the cursor is on, which is then the first line of the page
shown and has that line's place in the list, in one column and across a spread, where it
moves to the left-hand column, into the next chapter and back into the one before, and
again when the action is performed a second time with the cursor told of no other item; a
position shown from a line makes that element the line that holds it; VoiceOver's scroll
posts the page's number and then the element; and nothing is posted for a cursor on a
control, for VoiceOver switched off, for a page shown again as it was, or for a move by
heading. One test takes a single element through a book whose every page opens with another
kind of item, a table row, a picture, a link, a heading, a formula and a rule, and back: on
each page it must answer what a new element for that page's first item answers, in its
label, heading level, traits, language, frame and actions, and activating it must do what
that item does and nothing the last one did. Another takes the cursor through a book whose
pages open with a data table's cells of each kind, a header cell, a cell that is a link, a
cell of one picture and the cells of a table longer than a page, between pages of lines, and
back. A line's element must become the cell that opens the next page, in the list of that
page's table and not in the view's, with that cell's row, column, header cells and actions,
and a cell's element the line; each must be a cell, or not, to one who asks it as UIKit does
(`conformsToProtocol:` and `respondsToSelector:`). From a cell to a cell the element posted
must be the new cell's own, and the cell left what it was. A third does the same across an
iPad's spread, where the element changes column. They also hold an element kept from one page to
standing for no line of the next, on pages whose lines have the same characters counted
from each page's first, and to standing for its own line when its page is shown again. That
VoiceOver reads the line for the layout change, draws its cursor there and keeps its rotor,
is known only from [speech sessions](#voiceover-testing) on a device.

Table of data tests on AppKit (`TableDataMacAccessibilityTests`) read what a column and the
scroll view give an assistive technology at each row of a table that holds data, on a reader
built by the real pipeline, in pages and in continuous scroll: an `NSAccessibility` table of
its own at each row's character, called by that row's words and with that row selected; its
rows, each with its number in the whole table, its columns, and its cells with the rows and
columns each covers, the text areas each holds on screen and its place; a header for each
column and each row from the table and none from a cell, which is the header's own cell on
screen and otherwise a static text with the header cells' words, for a column under two
header cells, a header on another page and one scrolled far off the screen; a cell that
spans answering for every slot it covers; the actions a cell
offers, and that selecting a cell's words and following its link do so; a cell whose words
are one link and nothing else pressed to follow it, holding a link called by its words with
its text area inside, a header cell that is one link doing the same and still the header of
its row or column itself, a cell with words beside its link or with two links not pressed,
and a link cell far off the screen whose link holds nothing and whose press does nothing
until it is brought on screen, with a header cell that is a link heading its column by name
while it is off screen; a cell that shows pictures and nothing else holding an image for
each, called by the picture's words or by nothing, without help, where the picture is drawn
and with its Inspect Image, and no text area; a cell of decoration alone holding nothing; a
cell that shows a picture among words holding its text area and then the picture's image;
a header cell that is a picture still the header of its row itself; a cell that is a
picture's link holding its link; a picture cell far off the screen holding its image
there, where a cell of words with a picture among them is labelled with all of them; a
table split across pages, with the page's rows, the whole
table's count and a header cell named from another page; a row taller than a page, whose
words each page's table says once; continuous scroll, where a table holds every row, says
which are on screen and labels a cell that has no text area yet; and a table kept from a
page that has been turned, which says nothing of the new one. For a table that is not data
they read the group at each row's character: called by its cells' words in column order,
holding the text areas of the cells on screen, and the same element when one character is
asked for; a cell without words left out of the name, a described picture's words in it, a
row of pictures nobody describes with no name and no help, and a row of a table of data
that shows a picture still its table; in continuous scroll a row far below the screen the
same group with nothing in it, which holds its cells once it is scrolled to; a row taller
than a page called on each page by the words that page shows; and a group kept from a page
that has been turned, which says nothing. And they read what the text gives at a row that
has nothing to say, of cells that hold nothing or decoration alone, in a table marked as
layout and in a table of data: no element at its character; a space for that character and
for the break after it in the text's value, its string and its attributed string, each still
as long as the text, whether the row or its break alone is asked for; and no line of its
own, its line being part of the line after, with the rows of words each side a line apart
and the insertion point after the row on that line. They hold that a table of data entered
at another row still has such a row and its cells; that the lines follow one another through
a long table with one, two and three such rows together, each character on the line the
text gives for it and no line ending with such a row, where in continuous scroll the lines
are AppKit's and are numbered through the book; that such rows opening a text are part of
its first line, those ending one are a line together, and a text of them alone is one line;
and that a row is not passed over when it holds a picture nobody describes, a link or a
rule, while one of spaces, or with a table of decoration inside a cell, is. They read the
elements through AppKit's own accessibility methods, not the older informal ones, which do not
show what a client is given
([in-process accessibility actions](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#in-process-accessibility-actions)).
The SwiftPM test process (`swift test`) answers no client either: the accessibility API asked
of its own process id there gives `kAXErrorNotImplemented`. An app-hosted test bundle, by
contrast, reads its own app's tree without the Accessibility permission (EngineeringTestSupport's
`AccessibilityRead` reads one attribute;
[test hosts and what they reach](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#test-hosts-and-what-they-reach)).
To see what a client is given on this Mac without VoiceOver, build the verification reader,
launch it in the background with its `-SampleHref` arguments and ask it from another process,
as the client in
[#485](https://github.com/vocaro/EPUBLib/issues/485#issuecomment-6270877949) does. That a client of the
accessibility API is given each attribute, and what VoiceOver says, is recorded with the
[VoiceOver testing process](#tables-on-mac).

Table cell line tests on AppKit (`TableCellLineAccessibilityTests`) read the lines a cell's
own text gives an assistive technology: the layout's lines, numbered from the first the cell
shows and covering its text once; the offset after its last character on its last line, in a
cell of one line, in one of several, and in each part of a cell cut at a page's end; no line
for an offset past that one; and the insertion point's line with its characters, which is
what VoiceOver's Read Line has to read. One of them takes its cells from a table built by the
real pipeline and mounted on a page. VoiceOver said nothing for Read Line at the end of a
cell's text while that offset had no line.

Link tests on AppKit (`LinkAccessibilityTests`) read what a column and the scroll view give
an assistive technology for a link: one element for a link whose font changes inside it, with
its words, its place and a press that reports the link; the names of links that are pictures,
hidden labels and formulas, and never U+FFFC; a link element as the attachment of each
picture or label in a link, and none over a link's words; a hidden label's place, which has a
size though the label has none; a link cut at a page's end and continued on the next page;
the links on screen in continuous scroll; and a text view with no canvas, as a note's
popover has, left with AppKit's own. `TableCellLinkAccessibilityTests` read the same of a
table cell, which is a text view of its own: its links by what they say, with every range
counted from the first character the cell shows; a link element at each picture, label or
formula in a link and none at decoration after a link's first character; each link's place in
its cell and its press reporting the cell and the offset; a cell that shows only the later
lines of a row cut by a page; and the page, or the scroll view, listing its cells' links
among its own in reading order, as children of its own. What VoiceOver says of each is
recorded with the [VoiceOver testing process](#links).

Table cell tests on AppKit (`TableCoverageInteractionTests`) read what a cell's own text gives
an assistive technology for each attachment it can hold, on a table built by the real pipeline
with the entries of the VoiceOver fixture's seventh section: the reader's word for a rule, an
image named by its words for a formula and for a picture, a hidden label's words as text, an
image without a name for a picture nobody describes, and no element for decoration. They hold
each element to the place its character is drawn at, the same content in a page's text to the
same elements, a rule to having no words for a copy, a selection or its row, a part of a cell
cut at a page's end to the attachments of its own lines, and a table inside a cell to its
cells' words. One of them holds an element to outliving the string it was given in and to
being the same on the next read: VoiceOver read nothing at a cell's attachment while a cell
made its elements anew for every read. What VoiceOver says of each is recorded with the
[VoiceOver testing process](#voiceover-testing).

Highlight paint tests read the pixels the mounted reader's views last drew: none in the
highlight's color before a search, the matches after it, and none again after Clear Search,
with no reflow between. They cover both flows, one- and two-column spreads, dark appearance,
table cells, a highlight-only search and host highlights added and removed in place.
`ReaderPaintRecorder` copies each `draw(_:)` the system makes of a view under the canvas into a
bitmap kept for that view and composes those as the views are arranged. Rendering the view
does not serve
([capturing a background window](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#capturing-a-background-window)):
on Mac `cacheDisplay(in:to:)` and `CALayer.render(in:)` counted no highlight pixels while the
cleared matches were still painted.
`drawHierarchy(in:afterScreenUpdates:)`, which reads what UIKit composed, has no render server
in the simulator's test host. On Mac the tests turn off AppKit's text checking in the reader's
text views, whose redraw could repaint a stale surface before it was read. Set
`EPUBLIB_PAINT_DIR` to a directory to keep each step's picture and counts.

Control view tests read the platform controls SwiftUI builds for the supplied controls: the
Mac reading-mode segments' accessible names, values and actions, the picker's selection and
disabled state on both platforms, the search field's editing, submission and survival of its
pane beside a real reader, and that the field stands outside the reader's page keys. SwiftUI
draws the supplied buttons and menus itself and exposes them to no in-process test; their
names, capabilities and disabled states are checked in the model they read.

Coverage-gap suites (`…CoverageTests`, `SpecConformance…`, `EPUBCheck…`) come from a review
of the package by source area, against the EPUB Reading Systems 3.3 requirements one by one
and against EPUBCheck's scenario inventory. Their fixtures are original and built in code. A
test that exposes an open defect is marked as a known issue with its issue's URL, and a test
whose input kills the test process is disabled by name (`disabled_test…`) with its issue above
it, as
[honest outcome states](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#honest-outcome-states)
describes. A test of input that TextKit might never finish laying out runs the
layout under `BoundedLayout` (`BoxLayoutTerminationCoverageTests`), which stops the reader's
text container answering after a set number of calls. The container also has a bound of its
own, 1,000 calls running for one character
([#288](https://github.com/vocaro/EPUBLib/issues/288)); `UnplacedTextLayoutTests` puts back text
it ends, under a cap a hundred times that. Three [corpus runs](#corpus-runs) are opt-in: `EPUBLIB_W3C_EPUB_TESTS` (the `tests`
directory of w3c/epub-tests) holds each W3C reading-system test to an expected outcome,
`EPUBLIB_EPUBCHECK_FIXTURES` (`src/test/resources` of w3c/epubcheck) takes every EPUBCheck
fixture through opening, text extraction and a native build, and `EPUBLIB_EPUBCHECK_CLI` (the
`epubcheck` executable, macOS only) validates a matrix of written books.
`EPUBLIB_W3C_EPUB_TESTS_REPORT` (a file) and `EPUBLIB_EPUBCHECK_REPORT` (a directory) keep
their per-fixture results. Those runs fail today on the same open issues.

These are deterministic regression fixtures, not an EPUB conformance certification, a comprehensive
typographic review, an accessibility audit or a memory budget measurement. They do not establish
keyboard-only traversal, native toolbar overflow or iPhone Duo
layouts ([#51](https://github.com/vocaro/EPUBLib/issues/51)), which need live sessions.
The suite runs on OS 27; older platforms are outside the package's deployment targets. Simulator
coverage does not substitute for hardware performance and accessibility testing, except as the
next paragraph says.

For real VoiceOver sessions, use the [VoiceOver testing process](#voiceover-testing) and
the isolated `Examples/VoiceOverVerification` reader. Its diagnostic speech probe is outside
the local gate because it takes control of the user interface and changes VoiceOver state.
`scripts/run-voiceover-simulator.py` runs that probe on simulators of its own, with no window
and no sound, and takes over nothing: it records what a
[simulator's VoiceOver](#simulators) reads. What that record establishes, and what stays with
physical devices, is the shared
[acceptance rule](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#acceptance-rule)
([acceptance and evidence](#acceptance-and-evidence)).

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

`PublicationFolderCorpusTests` reads each W3C test and each expanded EPUBCheck fixture as a
folder and as the archive packed from it, and each archived EPUBCheck fixture and each book of
the two [collections](#books) as an archive and as the folder unzipped from it, and requires the
same publication or the same refusal ([#680](https://github.com/vocaro/EPUBLib/issues/680)); each
book zipped again must keep its `persistentID`
([#679](https://github.com/vocaro/EPUBLib/issues/679)). Each test is skipped without its
variable. A folder that lacks `mimetype` is held to the archive packed with one. An archived
fixture that is refused, or whose names a Mac's file system cannot hold as they stand (two that
differ only in case, a name that is not UTF-8), has no folder to compare and is listed as
skipped, with the reason, in the test's output:

```sh
eval "$(bash scripts/fetch-corpora.sh)"
swift test --filter PublicationFolderCorpusTests
```

### Books

Two public collections of books are standard corpora as well, chosen on 2026-10-14. Each is a
manifest in `scripts/corpora` that pins 50 EPUB files by URL and SHA-256, with the rule that
chose them in its header. The books stay outside the repository, beside the W3C corpora.

- **Project Gutenberg** (`scripts/corpora/gutenberg.tsv`): 50 English books, the EPUB 3
  "with images" build of each. `scripts/fetch-corpora.sh` fetches the missing ones, verifies
  all of them and prints `EPUBLIB_GUTENBERG`. Gutenberg's
  [robot-access policy](https://www.gutenberg.org/policy/robot_access.html) allows automated
  access only to the offline catalog, `robot/harvest` and the mirrors, so the URLs are on the
  mirror `robot/harvest` names (`aleph.gutenberg.org`, whose certificate names
  `aleph.pglaf.org`). Agents may fetch it through the script.
- **Standard Ebooks** (`scripts/corpora/standard-ebooks.tsv`): 50 books, the ordinary
  "compatible" EPUB of each. Its URLs end in `?source=download`. The plain URL answers with the
  site's "Your Download Has Started!" page, which sends a browser on to that URL; the owner
  chose it on 2026-10-14. Its robots.txt disallows `/ebooks/*/downloads/*` for AI agents'
  user agents (`claude-user`, `chatgpt-user` and others), so only the owner fetches it, with
  `bash scripts/fetch-standard-ebooks.sh --pin`. `scripts/fetch-corpora.sh` never downloads it;
  when its books are present and match the manifest, it prints `EPUBLIB_STANDARD_EBOOKS`.

Both fetchers (`scripts/corpora/fetch_books.py`) keep to each site's automated-access policy as
[corpus provenance](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#corpus-provenance)
describes, re-pinning included.

Neither collection versions its URLs: Gutenberg rebuilds its files monthly, and Standard Ebooks
republishes a book at the same URL whenever it changes. A book fetched after that fails its
SHA-256. The script keeps it beside the corpus as `NAME.mismatch-SHA12` and does not set the
variable. To re-pin:

1. Fetch every book afresh into a directory named for today, and write the new hashes and the
   date into the manifest. For Gutenberg, run
   `python3 -I scripts/corpora/fetch_books.py pin scripts/corpora/gutenberg.tsv ~/Library/Caches/EPUBLib/corpora`.
   For Standard Ebooks, the owner runs `bash scripts/fetch-standard-ebooks.sh --pin`.
2. Run the corpus tests on the new directory.
3. Commit the manifest, with the reason and the tests' results.

The old directory stays until someone removes it.

`BookCorpusPageTextTests` pages every chapter of the Project Gutenberg and Standard Ebooks
books in `EPUBLIB_GUTENBERG` and `EPUBLIB_STANDARD_EBOOKS` at six reader sizes, and checks
that every character is on a visible line of some page
([#570](https://github.com/vocaro/EPUBLib/issues/570)). It is skipped unless one of them is
set. It lays out every page twice, so run it in release, one process per size:

```sh
swift test -c release --enable-testable-imports --filter BookCorpusPageTextTests  # builds; skips
eval "$(bash scripts/fetch-corpora.sh)"
NSUnbufferedIO=YES EPUBLIB_PAGE_TEXT_CASES=phone xcrun xctest -XCTest EPUBViewingTests.BookCorpusPageTextTests \
  .build/release/EPUBViewingTests.xctest
```

The cases are `phone`, `phone-landscape`, `tablet`, `mac`, `small` and `phone-40pt`;
`EPUBLIB_PAGE_TEXT_BOOKS` names books by file name. The test's comment gives how long each
corpus takes.

On macOS, let a corpus layout process exit after its last test passes: AppKit's run loop can
hold its text views after the suite has passed
([an autorelease pool does not release what the run loop retains](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/framework-lifetimes.md#an-autorelease-pool-does-not-release-what-the-run-loop-retains)).
The [investigation of #589](https://github.com/vocaro/EPUBLib/issues/589#issuecomment-6283724393) records
the reader's callback counts and a comparison using plain AppKit views. The original
100-book ask-run probe continued for 1.8 to 32 minutes after passing at five sizes, and was
still running after 80 minutes at `phone-40pt`; these observations are not time limits.
Redirect such a run unbuffered, as above, and wait for its exit status
([hung and buffered test runs](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#hung-and-buffered-test-runs)).

`NativeCorpusQualificationTests` builds every book under `EPUBLIB_CORPUS`, a colon-separated
list of directories of EPUB files, and checks each section's text map:

```sh
eval "$(bash scripts/fetch-corpora.sh)"
EPUBLIB_CORPUS="$EPUBLIB_GUTENBERG${EPUBLIB_STANDARD_EBOOKS:+:$EPUBLIB_STANDARD_EBOOKS}" \
  swift test --filter NativeCorpusQualificationTests
```

The [first qualification](native-viewer.md#qualification) ran it on books that belong to
another project; EPUBLib does not depend on that project or its files, and they are not to be
used to test it.

## Probes and recorded inputs

What a measurement or a comparison found is on its issue. These are the scripts, variables
and inputs that repeat one.

### Simulator VoiceOver cursor activation

The scripts and inputs for [#495](https://github.com/vocaro/EPUBLib/issues/495) are in
[Investigating cursor activation](#investigating-cursor-activation): the guarded simulator
library, the startup canary, the assertion matrix and its stock negative control. The cache workflows replay both
#428’s first-line-after-scroll case and its move back past the chapter heading after a menu.
`python3 scripts/qualify-simulator-voiceover.py` runs the recorded reader and cache workflows;
`--workflow`, `--font-size` and `--device` select a narrower repeat. Results belong on the
issue, including the exact runtime build and whether the hook and canary confirmed it.

### Corpus teardown

The [reproduction on #589](https://github.com/vocaro/EPUBLib/issues/589#issuecomment-6283724393)
holds the reader instrumentation patch and standalone corpus and plain AppKit drivers, with
the commit the patch applies to and the commands to run them. The corpus driver lays out
every page column, optionally adds a whole-section scrolling view, then counts callbacks and
view releases while draining the run loop. The native comparison uses weak references to
count views retained after their autorelease pools end.

### UIKit note presentation in an app-hosted test bundle

The package XCTest host used here does not complete UIKit modal presentations
([package test hosts](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#package-test-hosts)).
Its note tests still verify routing, content, and activation order.
The app-hosted lane verifies the actual animated presentation, attachment, and dismissal.

The portable reproduction patch and its applicable commit are recorded on
[issue #257](https://github.com/vocaro/EPUBLib/issues/257#issuecomment-6174234834). Save that patch as
`note-apphost-reproduction.patch` and apply it from the repository root. The generated
project and all run output stay under the ignored `.build/verification/note-apphost/`.

```sh
git fetch origin
git show origin/main:AGENTS.md
git apply --check note-apphost-reproduction.patch
git apply note-apphost-reproduction.patch
bash .build/verification/note-apphost/run-note-apphosted.sh
```

This needs Xcode 27 with the iOS 27 simulator runtime, XcodeGen, Python 3, and Perl. The
runner creates and deletes its own iPhone 17 Pro and iPad Air 13-inch M4 simulators, always
addresses their UUIDs, and stops only children it started when interrupted. It disables
the debugger and code signing. `DEVELOPER_DIR`, `EPUB_SIM_RUNTIME`, and
`EPUB_SIM_BOOT_TIMEOUT` override the Xcode location, runtime, and boot timeout;
`NOTE_SIM_KIND=iPhone-17-Pro` selects just that device type when a narrower rerun is needed.

The scheme sets `EPUBLIB_NOTE_APP_HOSTED=YES`. Both devices must execute five
`NoteLinkSessionTests` and two `NoteUIKitPresentationControlTests`: seven passes, no failures
or skips. The runner holds filters in an array and checks the actual test-case pass counts
and `Executed 7 tests` summary, rather than accepting an empty filtered success. Optional
arguments select either of those two classes; the required counts remain five and two.

Each run prints its unique output directory. It records the tested commit, device-creation
output, boot logs, and test transcripts there.

### Search collation vectors

`SearchCollationVectorGenerator` runs the unchanged historical `search.js` and
`text-walker.js` through their real `searchMatcher`, on XHTML in WebKit. The source files
come from EPUBLib commit `4b7942d4d1682e60f505cb161c87b7757fb927ee` (`6e6930c^`).
The recorder writes the WebKit user agent and both source SHA-256 values into
`SearchCollationGoldenVectors.swift`:

- `search.js`: `31e846bdc095a645de0e94f7baa2c9e136561a363a2f774d4032e72cfa1fb0ef`
- `text-walker.js`: `4ad740ab6142b5be428700ef4d270253cef6649cf6e047ae7d2698a7aec65e92`

The 57 fixtures record 37 matching and 20 nonmatching searches. They cover Turkish dotted
and dotless I, Swedish and Spanish distinctions and merges, Cyrillic short I, untailored
accents, case/width, canonical spellings, Japanese kana, unqualified collations, explicit
German phonebook collation, primary prefixes, expansions, private-use suffix collisions,
emoji, inline boundaries, whitespace and overlapping matches. Each recorded range is
compared with both the filtered and complete native scans.

The golden tests require every recorded locale equivalence to share a prefilter key,
cross-root-class merges included. Root collation matches also require exact equality with the
WebKit classes, with no exception for the Cyrillic short I. Mounted-session tests verify that
`.locate` and `.searchHighlight` produce the same ranges and misses in Swedish, Turkish,
Spanish and Russian, including body language overriding root language
([native viewer](native-viewer.md#decisions), "Search collation"; the run of
[#26](https://github.com/vocaro/EPUBLib/issues/26#issuecomment-6159293346)).

Regenerate the vectors and run those tests with the extracted historical source files and a
dedicated scratch directory:

```sh
git show '6e6930c^:Sources/EPUBViewing/Resources/epub-reader/lib/search.js' > /tmp/foliate-search.js
git show '6e6930c^:Sources/EPUBViewing/Resources/epub-reader/lib/text-walker.js' > /tmp/foliate-text-walker.js
EPUBLIB_GENERATE_SEARCH_COLLATION_VECTORS=1 \
EPUBLIB_FOLIATE_SEARCH_SOURCE=/tmp/foliate-search.js \
EPUBLIB_FOLIATE_TEXT_WALKER_SOURCE=/tmp/foliate-text-walker.js \
swift test --scratch-path .build/issue-26 --filter SearchCollationVectorGenerator
swift test --scratch-path .build/issue-26 \
  --filter 'TextSearchTests|CFIGoldenVectorTests|NativeSessionCollationTests'
```

### Networking SVG book

The SVG tests that read a real book take Charles R. Severance's *Introduction to Networking*,
available under CC BY 4.0 from the [publisher](https://www.dr-chuck.com/net-intro/). The
unchanged [English EPUB](https://do1.dr-chuck.net/net-intro/EN_us/net-intro.epub) is
2,752,493 bytes and has SHA-256
`54d3886b30e92daca03f2f66065c01cb0d48c592824365605308b7b542c45c6d`. The book is optional and
is not copied into this repository. Its linear spine has 37 `<img>` elements: the cover, one
photograph and 33 SVG resources, two of them shown twice. Six of the SVG resources hold a
shadow filter (`file5`, `file8`, `file11`, `file19`, `file24`, `file33`) and 13 hold `<text>`.

```sh
EPUBLIB_SVG_CORPUS=/tmp/issue-53-net-intro.epub \
EPUBLIB_SVG_CORPUS_VISUAL_OUTPUT=/tmp/issue-53-networking.png \
swift test --filter 'SVGRelayoutTests|SVGRenderingTests'
```

Given the book, the corpus test of `SVGRenderingTests` renders all 33 SVG resources and checks ink
in each label's region of the four-layer diagram, `media/file5.svg`, and
`SVGRelayoutTests.testOriginalNetworkingFiguresSurviveRelayoutWhenProvided` requires 37 of 37
figures mounted at every step of a resize and restyle. Without it both skip. A simulator's tests
take the same file from `TEST_RUNNER_EPUBLIB_SVG_CORPUS`. The runs are on
[#53](https://github.com/vocaro/EPUBLib/issues/53#issuecomment-6159293638) and
[#54](https://github.com/vocaro/EPUBLib/issues/54#issuecomment-6159293824).

### SVG rendering cost probe

The renderer probes and their recorded inputs moved to StaticSVG with the renderer: its
[rendering cost probe](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/testing.md#rendering-cost-probe)
and [font-size cost probe](https://github.com/vocaro/StaticSVG/blob/0.1.1/doc/testing.md#font-size-cost-probe).
The measurements already recorded stay on [#176](https://github.com/vocaro/EPUBLib/issues/176#issuecomment-6159294552)
and [#443](https://github.com/vocaro/EPUBLib/issues/443).

`RichMediaSVGRenderingCostCoverageTests` keeps, for each stylesheet and text bound, the book a
drawing past it is in: the section shows its fallback text with the `svg` disclosure. Whether
each drawing is past its bound, and that ordinary drawings stay within every one, is tested in
StaticSVG, as are the screens' other bounds; this repository keeps the tests that need a book
(archive and inline SVG, manifest fallbacks, HTML-recovered SVG, fonts, relayout, disclosures).

### Attribute parser cost probe

For [#196](https://github.com/vocaro/EPUBLib/issues/196), save the standalone probe below as
`/tmp/attribute-cost.c`. It generates one `p` with distinct `a0='v'`, `a1='v'` attributes
inside `html/body` and profiles only the SDK's libxml2 XML and HTML parsing. It uses no
repository code; the parser CPU measurements and system disassembly are recorded in the
[#196 qualification comment](https://github.com/vocaro/EPUBLib/issues/196#issuecomment-6161992517).
The safety limit is described in [text extraction](text-extraction.md#contract).

```sh
xcrun clang /tmp/attribute-cost.c -I"$(xcrun --show-sdk-path)/usr/include/libxml2" -lxml2 -o /tmp/attribute-cost
/tmp/attribute-cost 40000
/tmp/attribute-cost 80000
```

```c
#include <libxml/parser.h>
#include <libxml/HTMLparser.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int n = atoi(argv[1]);
    if (n < 1 || n > 100000) return 2;
    char *s = malloc(n * 30 + 100);
    if (!s) return 2;
    int length = sprintf(s, "<html><body><p");
    for (int i = 0; i < n; i++) length += sprintf(s + length, " a%d='v'", i);
    length += sprintf(s + length, ">text</p></body></html>");
    for (int k = 0; k < 3; k++) {
        clock_t start = clock();
        xmlDocPtr doc = htmlReadMemory(s, length, NULL, "UTF-8",
            HTML_PARSE_NONET | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING | HTML_PARSE_RECOVER);
        printf("HTML attrs=%d bytes=%d CPU=%.6f\n", n, length,
            (double)(clock() - start) / CLOCKS_PER_SEC);
        if (doc) xmlFreeDoc(doc);
    }
    clock_t start = clock();
    xmlDocPtr doc = xmlReadMemory(s, length, NULL, "UTF-8",
        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
    printf("XML attrs=%d bytes=%d CPU=%.6f\n", n, length,
        (double)(clock() - start) / CLOCKS_PER_SEC);
    if (doc) xmlFreeDoc(doc);
    free(s);
}
```

`ParserPreflightSafetyTests` and `NativeParserPreflightSafetyTests` assert the accepted boundary
and typed refusal, including duplicate/boolean attributes, wide encodings and HTML contexts
that differ from XML. Their acceptance assertions do not measure time.

### Archive input work probe

The constructed release-build inputs confirm that small output does not bound work. Each extra
directory record has its own `extra/N.bin` path and a zero CRC and uncompressed size. The base is
the repository's original seven-file, two-chapter fixture; no external books are used.

`Fixture.sharedInputArchive` writes one local header, or distinct headers whose extra fields
overlap and end at the same data start. Its Deflate stream is a run of empty stored blocks with
only the last block final (4,194,300 bytes for the 4 MiB request). The early-end control begins
with the final empty fixed-code block `03 00`, followed by 4 MiB of unused zeros. Directory records
declare the whole stream, including those unused bytes. The long-header case has a 65,535-byte
name and a 65,535-byte extra field, held once in the archive and repeatedly named by records.

Each input runs in its own child with a 120-second timeout; fixture construction and a
warm-up opening precede the clock. From the repository root:

```sh
python3 scripts/measure-archive-input-cost.py --repeats 1
```

`--zipfoundation /path/to/ZIPFoundation` reuses a public 0.9.20 source checkout without modifying
it; otherwise SwiftPM resolves the exact 0.9.20 dependency. The script creates a separate package
under `.build/measure-archive-input-cost`, linking this checkout's source and original fixture
code, and builds only the release probe's dependencies. It also defines the real reading test
target, so focused regression and size-policy checks can reuse that build:

```sh
swift test --package-path .build/measure-archive-input-cost -c release -j 2 \
  --filter 'ArchiveInputWorkTests|ContainerArchiveCoverageTests|PublicationSafetyTests|ArchiveEndRecordTests|ZIP64ZeroValueTests|ArchiveInputReleaseTests'
```

The release measurements of 2026-10-13, without the bound and with it, are on
[#199](https://github.com/vocaro/EPUBLib/issues/199#issuecomment-6159294787);
[architecture](architecture.md#publication-model) has the bound.

### Archive mutation probe

`Issue74MutationProbe` opens seeded mutations of the repository's own fixture and counts what
`EPUBPublication.open(data:)` returns: an open, each `EPUBPublicationError` case, or an error of
any other type. Half of the mutants come from `Fixture.epub()`, which is deflated, and half
from the same files stored. They are spread evenly over five kinds: random bytes, a size field,
a method field, bytes in an entry's data, and bytes in an entry's data with its directory
declaring 32 MiB to 2 GiB. The patch is on
[#74](https://github.com/vocaro/EPUBLib/issues/74#issuecomment-6270962133), with the commit it
applies to and its run comparing `main` with that issue's fix. Save the patch as
`issue74-probe.patch`, apply it from the repository root, and remove the file it adds
before committing:

```sh
git apply --check issue74-probe.patch
git apply issue74-probe.patch
EPUBLIB_ISSUE74_MUTANTS=100000 swift test --filter Issue74MutationProbe/testProbe
```

`EPUBLIB_ISSUE74_OUT=<file>` writes one line per mutant, for comparing two builds mutant by
mutant. `EPUBLIB_ISSUE74_REPLAY=<index,…>`, with `--filter Issue74MutationProbe/testReplay`,
opens the listed mutants 20 times each in one process. `Fixture.epub()` writes the current
time into each header, so its mutants are the same bytes only within one process. The stored
mutants are the same bytes in every run. Before [#583](https://github.com/vocaro/EPUBLib/issues/583),
some damaged Deflate streams did not give the same result on every open, because Apple's
decoder read stack memory it had not set
([Apple's Compression inflater](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/document-parsing.md#apples-compression-inflater-is-not-deterministic-on-damaged-streams));
deflated entries are now inflated with zlib.

### Generated page text

`PageTextGeometryTests` and `PageTextPreservationTests` lay out generated sections and hold
every page of them.

Every generated page checks actual native line and glyph-edge rectangles against its effective clip.
Source offsets alone are insufficient for tables: each original row's complete word tokens are
compared with the accumulated tokens of its visible continuation attachments, grouped by original
source offset. Missing or duplicated cell words fail independently of source-character coverage. The
tall-table integration test additionally holds 900 unique words across narrow and wide columns.
Oversized headings and extreme positive/negative baseline shifts retain their source and semantic
roles. A genuine negative-height final fragment of a multi-paragraph positioned box holds hit
testing, links, visible ranges, line boundaries and CFI restoration against raw glyph coordinates.

```sh
PAGE_TEXT_SECTIONS=500 PAGE_TEXT_REVIEW_SECTIONS=500 PAGE_TEXT_SEED=12 \
  swift test --jobs 1 --filter 'PageTextGeometryTests|PageTextPreservationTests|ExhaustedLineInsetTests|BoxPaginationIntegrationTests|LongParagraphPaginationTests'
```

The generated tests default to 24 sections for the ordinary gate. The historical diagnostic reports
are evidence, not an alternative runtime oracle; production preserves the established eligibility
decisions and tests its actual native output.

`PageTextGeometryTests.testGeneratedBoxPagesExposeAllSectionCharacters` uses indexed reset
selection. `testFrozenReviewGeneratorExposesEveryCharacterAndTableWord` consumes the reset draw
before generation, exactly as the reviewer generator recorded on
[#242](https://github.com/vocaro/EPUBLib/issues/242) does. Their section numbers are not
interchangeable. `PageTextPreservationTests` stores frozen actual pixel vectors for the critical
opening pages and every page of the generated section g12#275.

Three of those tests have a UIKit branch, because macOS page boundaries and font metrics are
not UIKit's. The larger delayed-proposal fixture preserves every displayed rectangle and
source boundary on both. UIKit places its table rows at source offsets 235, 237 and 239
inside page zero, at Y130.8, Y155.8 and Y180.8, and does not exercise the macOS delayed
first-fragment trigger. The Mac test requires the semantic second row to open its page at
Y603.15 with width 1024; the UIKit branch pins the independently captured in-page Y155.8 and
full width, then checks all characters and visible table words. Neither platform silently
skips the fixture. The g275 fixture's UIKit contract checks complete source coverage, visible
table words, native line bounds and every painted character's horizontal and vertical segment
rectangle within 0.01 points, where the four readable macOS pages keep their exact frozen
vectors and boundaries.

Tests of the least clip the typography fallback needs check the two-point effective-clip
threshold and just below it, both with and without retained top spacing. At viable
12/24-point page heights and 500-point oversized-glyph pages, every nonwhitespace source
character's native segment rectangle must fit the effective clip within 0.01 points; complete
source partitions and boundary/interior/end page lookups remain checked.

The qualification of 2026-10-13 against a frozen `main`, with its paired UIKit data, is on
[#242](https://github.com/vocaro/EPUBLib/issues/242#issuecomment-6159295037).

`BoxPlanAgreementTests` holds the box plan to the section's layout: every planned line starts
where the layout's line at the same character does, within 0.75 points, in generated sections
whose indented tabs, tabbed table rows, tables with margins, captions, empty paragraphs,
right-to-left text, drop caps and list markers stand above, between and below floats and
positioned boxes, and every page of
those sections passes `PageTextGeometryTests.assertVisiblePages`
([#377](https://github.com/vocaro/EPUBLib/issues/377)). Sections whose boxes are all left in
flow have no plan and are skipped. It defaults to 24 sections:

```sh
BOX_PLAN_SECTIONS=300 BOX_PLAN_SEED=377 swift test --jobs 1 --filter BoxPlanAgreementTests
```

`BOX_PLAN_ONLY=12,20` checks only those sections, and `BOX_PLAN_DIAGNOSTICS=1` prints each
section's markup.

`TableNarrowCellTests` generates tables whose cells hold lists with markers of any width,
padding, negative and positive text indents and nested tables, in either direction. At widths
from 24 to 120 points and page heights from 24 to 240, every cell, nested ones included, is as
tall as its last line reaches and each of its lines is in exactly one slice of its rows; paged
at small viewports, every page passes `PageTextGeometryTests.assertVisiblePages`. It also holds
#569's reproductions and #377's nested cell to their words in each page's Copy text and in what
VoiceOver reads there ([#569](https://github.com/vocaro/EPUBLib/issues/569)). It defaults to 24
tables; `TABLE_NARROW_SECTIONS` and `TABLE_NARROW_SEED` (default 569) choose them:

```sh
TABLE_NARROW_SECTIONS=400 swift test --jobs 1 --filter TableNarrowCellTests
```

`PageMeasurementTests` holds the sections that lost characters before every page was measured
([#570](https://github.com/vocaro/EPUBLib/issues/570)), each by its whole-page character rule:
`PageTextGeometryTests`' seed 22 section 443, small justified and Chinese-text paragraphs, lines
taller than their page that mix large and small runs or text and a table row, and a page whose
own first line holds a tall row. It holds the pages whose characters were on no visible line
before [#576](https://github.com/vocaro/EPUBLib/issues/576): a page whose own layout sets none
of its characters on a line (a continued line whose tab no stop follows, its interval taken
away by hand), a formula taller than its clip below kept spacing, and a line of two
attachments the fallback does not size, which is divided between pages. It also holds a
justified paragraph of verse, a `<br>` after each line: a page inside it lays out the paragraph only up to the next line break that ends a
line of text, with the same lines and character positions as with the paragraph's whole rest. Its generated sections have no box plan and pages ending
inside justified, tabbed and indented paragraphs; `PAGE_MEASUREMENT_SECTIONS` (default 120)
and `PAGE_MEASUREMENT_SEED` (default 570) choose them.

### Layout ask-run probe

`AskRunProbeTests` wraps `ReaderTextContainer`'s answer to TextKit, as `BoundedLayout` does, and
records for every run of requests for a line at one character how many requests it reached.
Its run is in its test; the bound it measures is `askLimit`
([#288](https://github.com/vocaro/EPUBLib/issues/288)). It lays out every section of each
publication as `BookCorpusPageTextTests` does, paged at the reader's column size for each of its
cases with every page laid out again as its column shows it, and adds the whole section in one
scrolling column. It also counts the characters on no visible line and the sections whose report
has `textNotLaidOut`. A self-check first puts a paragraph with no tab interval beside a float and
must see the bound end it. `RecordCostProbeTests`, in the same patch, times the record's
attribute added over each section of a directory of books.

The patch, and what it measured on the fixture books and every corpus, is on
[#288](https://github.com/vocaro/EPUBLib/issues/288#issuecomment-6273856806). Save it as
`ask-run-probe.patch`, apply it from the repository root, and remove the files it adds before
committing:

```sh
git apply --check ask-run-probe.patch
git apply ask-run-probe.patch
eval "$(bash scripts/fetch-corpora.sh)"
EPUBLIB_ASK_PROBE=fixtures,w3c,epubcheck swift test --filter AskRunProbeTests
```

`EPUBLIB_ASK_PROBE` names any of `fixtures`, `w3c`, `epubcheck`, `gutenberg` and `standard`, and
`EPUBLIB_PAGE_TEXT_CASES` narrows the sizes. The book corpora take 9 to 61 minutes a size in a
release build, so run them one process per size, as for `BookCorpusPageTextTests`. The probe
prints one `ASK-PROBE` line, and with its output going to a file that line is written only when
the process exits. The process can go on for an hour after its test
([#589](https://github.com/vocaro/EPUBLib/issues/589)); use `NSUnbufferedIO=YES` or
`script -q <log>` to see each line as it comes, and let it exit
([Corpus runs](#corpus-runs)).

### Reader controls probe

`Examples/ControlsQualification` is the host: `EPUBReaderView` in an ordinary `NavigationStack`
with `EPUBReaderToolbar` for search, contents, appearance and reading mode at `.topBarTrailing`
and the page buttons at `.topBarPinnedTrailing`, as [reader-controls.md](reader-controls.md)
shows. Launch arguments swap in the embedded `EPUBReaderControlStrip`, or a host-placed
`EPUBSearchResultNavigator` in the bottom bar with `EPUBSearchResultList` in a sheet, and add
host actions beside the supplied groups.
A line under the reader prints the reader's public state, so each control's effect can be read
back. Its three books are synthetic (`scripts/make-controls-fixture.py`):

- **The Lantern Road**: six documents, contents nested four deep with an unlinked heading and
  an unlinked entry, a page list, "lantern" 14 times (three in one paragraph), "heron" once.
- **طريق المصباح**: Arabic, with a right-to-left page progression and nested contents.
- **Two Hundred and Forty Stages**: 240 documents, 480 "lantern" and more than 10,000 "the".

`ControlsProbe`, a UI test, performs one step per line of a file (tap this name, type, rotate,
dump the tree) and keeps a log, the accessibility tree and a screenshot after each step.
`scripts/run-controls-qualification.py` runs one scenario and does what only the Mac can do
mid-run: set the simulator's text size, capture each display, fold the Duo. The probe asserts
nothing: what a run shows is read from its logs, trees and screenshots.

A run's log, trees, screenshots and result bundle go under `.build/qualification/runs/`, one
folder per scenario with its `meta.txt`. None of it is committed. The Mac's screenshots show
the whole screen and stay local.

```sh
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
python3 scripts/make-controls-fixture.py
xcodegen generate --spec Examples/ControlsQualification/project.yml
DEVICE=$(xcrun simctl create "controls-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-27-0)
xcrun simctl boot "$DEVICE"
xcrun simctl bootstatus "$DEVICE" -b
xcodebuild -project Examples/ControlsQualification/ControlsQualification.xcodeproj \
  -scheme ControlsProbeIOS -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath .build/qualification/derived build-for-testing
printf 'tap=Search\ntype=lantern\nkeyboard=search\ndump=results\ntap=Next Match\nstatus\n' > steps.txt
python3 scripts/run-controls-qualification.py --device "$DEVICE" --name search \
  --args "-QualificationBook ltr" --steps steps.txt
xcrun simctl delete "$DEVICE"
```

The first line is the default of `scripts/test-ios.sh`; the runner has it too, whatever
`xcode-select` names, and does not run a probe that another Xcode built. `keyboard=search`
touches the keyboard's own key, the Return of a field whose submit label is Search, rather than
typing a Return
([#307](https://github.com/vocaro/EPUBLib/issues/307#issuecomment-6132965039) has the counts).
Each `dump` line of the log says whether the keyboard was on screen and what had keyboard
focus, and on iOS every scenario starts upright. What these probes found about input, touches,
text sizes and runs stopped part-way is in
[UI test input and observation](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#ui-test-input-and-observation),
and a new simulator's keyboard card is dismissed as
[Device Hub](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#device-hub)
says.

A step that names an element compares its word with each element's label, then its identifier,
placeholder and title: the first of those that any element carries the word in decides, and the
others are passed over. It names the application's own elements only. The keyboard's keys, its
predictions and its Emoji and Dictate buttons, everything in the keyboard's window, are touched
with `keyboard=` alone. A word that names several elements is refused, with each listed, unless
exactly one of them is hittable, and `Word@N` takes the one listed as `@N`. `find=Word` lists
what a word names and what it passes over. Before
[#366](https://github.com/vocaro/EPUBLib/issues/366) a step took the first hittable element
that carried the word in any of the four, and with the keyboard up `tap=Search` pressed the
keyboard's Search key, whose identifier is Search, in place of the search field's button. A
`tap=search` written for Return then now does nothing, and its line names `keyboard=search`.

The probe's steps are documented where they are handled, in
`Examples/ControlsQualification/UITests/ControlsProbe.swift`. `key=` types a hardware key
with `XCUIElement.typeKey`, through UIKit's own keyboard dispatch, after any of `shift+`,
`command+`, `option+`, `control+` and `function+`. On 2026-10-22, on an iPad Air 13-inch (M4)
simulator with iOS 27.0 (24A434) and Xcode 27.1 (27A9275), the reader received Right Arrow,
Down Arrow and Space that way. It received no press at all for `key=home`, `key=end`,
`key=pageup` or `key=pagedown`, with or without `function+`, so the probe cannot show those
keys on iOS. The status line ends with the layout's page, counted from 1, as
`layout page 2/22, section 1/5`, with `-` where a count is not known yet
([#681](https://github.com/vocaro/EPUBLib/issues/681)). Host arguments:
`-QualificationBook ltr|rtl|long`, `-QualificationHost toolbar|strip|navigator`,
`-QualificationPlacement automatic|leading|bottom`, `-QualificationHostItems <count>`,
`-QualificationFlow scrolled`, `-QualificationFontSize <points>`, `-QualificationTitle NO`,
`-QualificationTouchTrace YES`, for the strip `-QualificationStripGroups <names>` (its groups
in order, as `pages,contents,appearance,readingMode`) and `-QualificationStripRoom <points>`
(the most height it is offered), and, on the Mac, `-QualificationWindowSize <width>x<height>`.
`-QualificationHides YES` puts the host under `epubReaderHidesControls`, with Hide Controls in
its toolbar, and `-QualificationHidesWhileReading NO` has the controls hide only when asked
([hiding the controls](reader-controls.md#hiding-the-controls-while-reading)). The status line
then ends in "controls hidden" or "controls shown", and states "contrast increased" and
"transparency reduced" while those are on. A step `target=com.apple.Preferences` has the steps
after it operate the simulator's own Settings, for a setting no simctl command makes, such as
iOS 27's Liquid Glass under Appearance, and `target=host` comes back to the host, which kept
running.
UIKit's own `-UIPreferredContentSizeCategoryName`, with a category the guide above names,
gives the host a text size without a change to the simulator; on the iPhone SE the strip's
frames at the largest size were those `signal=content_size` gave. For the iPhone Duo set
`DEVELOPER_DIR` to Xcode 27.1 for the build and the run, and pass `--hinge-script`
([setting a pose](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#setting-a-pose)
says what never to send that simulator). For the Mac pass `--mac` in place of `--device`, with
a signed build, and run it there only with the owner's explicit authorization: the probe takes
the Mac's pointer and keyboard.

With `-QualificationTouchTrace YES` the host records every touch where the application
receives it, as the guide above describes: the view it went down on, when it had moved 10
points, when each scroll view began to drag, and the scroll views, the keyboard and any menu
before it, as it lifted and a second later, with a picture of the window then and the touch
drawn on it, and the application leaving the foreground or its main thread standing still. The
lines go to the host's standard output and, with the pictures, to
`Documents/touch-trace-<launch time>/` in its container:

```sh
ls "$(xcrun simctl get_app_container "$DEVICE" org.epubreaderlib.controlsqualification data)/Documents"
```

A `drag` step rests a tenth of a second before it moves. Two more numbers set the rest in
seconds and the speed in points a second, and a seventh keeps the touch down at the end, which
leaves a scroll view where the touch took it and not where a fling would:

```sh
printf 'drag=0.5,0.52,0.5,0.22,0,1500\ndrag=0.75,0.27,0.75,0.46,0,300,0.6\n' > steps.txt
```

The first is a swipe of 200 points from the middle of an upright iPhone SE; the trace gave its
rest as 0.02 s. With a rest of 0.05 the trace gave 0.08 to 0.10 s, and with 0.3, 0.32 to
0.45 s. The second moves the strip of an iPhone SE on its side 64 points and leaves it there.
The `tree` line of a run's `meta.txt` speaks for `Sources` alone: a change to the host or the
probe is not in it. The same host runs on a device, for a finger: build the
`ControlsQualification` target for it, install and launch it with `devicectl`, and copy the
trace back with `devicectl device copy from --domain-type appDataContainer`. It recorded one
tap on an iPhone 17 Pro Max (iOS 27.2) that way, and nothing more was tried there.

The host's record of any touch gives the strip's scroll view, the height of its groups and
the height it has, which is how the tables for
[#385](https://github.com/vocaro/EPUBLib/issues/385) were read.

The Mac VoiceOver sessions over the strip ran on the hosted runner, as
[Hosted Mac sessions](#hosted-mac-sessions) describes, with one more `-f ref=` for a branch
that makes the Mac's strip a scroll view. That branch removes the two `#if os(macOS)`
conditions from `EPUBReaderControlStrip`, so that its body is the scroll view on every
platform.

```sh
STEPS='ax:next ax:focus left left left left left left left left left left left right right right right right right right right right right right'
python3 scripts/hosted-run.py voiceover-mac.yml -f width=1100 -f steps="$STEPS"
python3 scripts/hosted-run.py voiceover-mac.yml -f ref=SCROLL_VIEW_BRANCH -f width=1100 \
  -f steps='ax:next ax:focus left left in right right right right right right right right right right right out right right'
```

What the probe saw, what was fixed and what is still unverified is on
[#51](https://github.com/vocaro/EPUBLib/issues/51#issuecomment-6159295619) ([second
part](https://github.com/vocaro/EPUBLib/issues/51#issuecomment-6159295950)).

### VoiceOver's own code on Mac

What VoiceOver does with an element can be read in its own code, without running it or
attaching to it, as
[reading VoiceOver's own code](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#reading-voiceovers-own-code)
describes
([inspecting system code without starting it](https://github.com/vocaro/apple-engineering/blob/main/guides/shared-host.md#inspecting-system-code-without-starting-it)).
The helper that names the stubs and strings in that output is on
[#485](https://github.com/vocaro/EPUBLib/issues/485#issuecomment-6272726811):
`cacheread.c` and `annotate.py` read the shared cache as their own process maps it, and write
each stub's selector or function and each string's characters beside the line that uses it.
Read so on macOS 27.0, the code is what made a departed table of data say "empty" on 27.0.1
([the native viewer](native-viewer.md), "Data tables", "Pages").

## Adapter contract tests

The **EPUBViewingTestSupport** target exercises engine contracts with `EPUBEngineContract.verify`.
It is internal: `Package.swift` ships no product for it, so only this package's tests link it
([#748](https://github.com/vocaro/EPUBLib/issues/748)). It uses no XCTest or renderer types, so a
test can call it from XCTest, Swift Testing or another async test runner. Provide a validated
two-section publication, two distinct encoded resource hrefs, a phrase present in the first section
with two or more search results in the publication, and a `mount` closure that places the session in
a visible test window and returns a cleanup closure retaining that window.
`NativeSessionTests.testReusableEngineContract` is a complete call-site example.

The verifier checks:

- A pre-cancelled command throws `CancellationError`.
- The mounted session emits `.ready` exactly once.
- Advertised commands can be submitted; unsupported commands return the matching capability error.
- Href navigation changes sections and bookmark restoration returns to the saved section.
- Locations carry the publication's `persistentID` and a valid engine-tagged bookmark when
  supported, and a location that carries the book's `id` instead, as one saved before
  `persistentID` does, restores too ([#679](https://github.com/vocaro/EPUBLib/issues/679)).
- Foreign publication, engine and bookmark format identities are rejected.
- An engine with `.searchResults` lists the phrase's results before reporting completion, with
  indices in order and the publication's identity; steps, wraps back from the first result to
  the last and on from the last to the first, and selects as
  `EPUBSearchResults.steppedIndex(forward:)` says; mirrors the list in `readerState` when it has
  one; refuses an unlisted result, whether its index is out of range or names a listed one; and
  withdraws the list on clear, after which a kept result is refused and no step has any effect.
  The engine must list two or more results for the phrase, or the verifier fails before it
  steps: with one, every step would show that result, and no step or wrap could move the
  current match. An engine without `.searchResults` refuses the three result commands with
  `.unsupported(.searchResults)` and publishes no results.
- Close is idempotent; closed commands fail and later callbacks are suppressed.

A minimal SwiftUI test engine runs the same checks with no renderer at all, as an engine with no
search, one that only highlights, one that lists results, and one that lists them and reports a
step's relocation and a clear's idle state 30 ms late, from a timer of its own. Deliberately broken
engines demonstrate that missing/duplicate readiness, ignored cancellation, incompatible restoration,
locations that carry the file's hash, a restore that refuses a location saved under it,
late callbacks, results published after completion, steps that do not wrap, stale results that
still navigate, results kept after a clear and a step of a cleared search that still moves the
reader fail the verifier. Adapter-specific tests must additionally check actual rendering,
selection gestures, precise bookmark semantics and resource release.

A bounded quiet period after close detects late callbacks; it cannot prove that an engine will
never emit a much later event. The verifier waits as
[late callbacks and quiet periods](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#late-callbacks-and-quiet-periods)
describes: it yields, waits 150 ms, waits 20 ms more and then looks. A look at the moment the
150 ms ended missed a callback sent from a 30 ms sleep one time in ten on GitHub's hosted
runner, when these tests ran there on 2026-10-12, and a few times in a thousand on a busy Mac.
So one broken engine queues its late callback and another sends it from a 30 ms sleep, and
both are caught.

The 20 ms is a margin and not a bound. With the race made as that guide describes
(`kill -CONT` 200 ms after `kill -STOP`), on this Mac under heavy load on
2026-10-13, the callback came after the 150 ms had ended in 1,416 of 11,235 attempts: within a
millisecond in 1,402 of them, and more than 20 ms after in two, at 29 ms and 42 ms. Without the
yield it came more than 20 ms after in 39 of 11,304.

The search-results check waits the same way twice more, through the same `settle()`. After the
clear it waits before it counts the events, so that what a correct engine still sends for the
clear, its idle state or a relocation, is not taken for the effect of a stale step. After the
stale steps it waits before it looks for that effect. With both sleeps made overdue together, a
count taken the moment the 150 ms ended failed a correct engine that reports from a 30 ms sleep
in 667 of 2,954 attempts, and a look at that moment let through a broken engine whose stale
step moves the reader from a 30 ms sleep in 126 of 3,013. Waiting as after close, neither
happened, in 2,979 and 3,028 attempts. Both engines are in `EngineContractTests`: the first must
pass and the second must fail. The wait before the clear is a plain 150 ms. An event that comes
just after it is counted all the same, by the wait after the clear: one did in 100 of 1,430
attempts, and the engine passed in every one.

The contract verifier requires at least two distinct section hrefs when the engine advertises href
navigation. It permits a navigation to the already-current section to be a no-op. `send` acknowledges
submission, so fidelity checks must wait for events or inspect the mounted renderer themselves
([command submission is not completion](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/command-lifecycles.md#command-submission-is-not-completion)).

## VoiceOver testing

Use real VoiceOver speech to verify the paginated reader on a Mac, iPhone and iPad. What each
lane establishes, a [simulator's VoiceOver](#simulators) among them, is the shared
[acceptance rule](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#acceptance-rule);
[Acceptance and evidence](#acceptance-and-evidence) says which a check needs. The sessions
are recorded in the
[Mac verification](https://github.com/vocaro/EPUBLib/issues/55#issuecomment-6159294286) and the
[iPad and iPhone verification](https://github.com/vocaro/EPUBLib/issues/28#issuecomment-6159294047); the acceptance matrix is in
[#28](https://github.com/vocaro/EPUBLib/issues/28).

### Isolated reader and fixture

`OPS/math.xhtml` contains generated readings of x squared in English, French, German, Spanish
and Italian, an unsupported Japanese request that falls back to English, authored German
`alttext`, a native addition stack and a long inline sum. Open it with
`-SampleHref OPS/math.xhtml`. Simulator speech sessions can touch `x squared`, `x au carré`,
`x Quadrat`, `x al cuadrado`, `x al quadrato`, and `Die eigene Beschreibung`; a Mac session
can focus the reader and move by line. The generated reading's text and language attributes
are also held by `MathSpeechTests` and `MathCanvasTests`. These checks distinguish the words
and requested voice language from subjective vocabulary review upstream.


`Examples/VoiceOverVerification` runs the reader screen in its `Shared` folder, with its own
application identifiers and a bundled synthetic EPUB. That screen was the sample app's until the
app was removed on 2026-10-20 ([#700](https://github.com/vocaro/EPUBLib/issues/700)). "The
sample" in the records below is that screen, and its `-Sample…` launch arguments kept their
names. It opens the fixture at launch
without a file-picker interaction. The book contains `word0001` through `word1200` in one
justified paragraph, a heading, an internal **Verification link**, and an image labeled
**Blue verification square**. Its long paragraph retains the continuation context that
originally exposed off-page text. A second section, **Hidden labels** (`OPS/labels.xhtml`),
holds what a book hides from the page and keeps for assistive technology: a heading and a
byline parked at `left: -999em` above an image with an empty `alt`, as a Standard Ebooks title
page has them, words clipped to nothing inside a line, and a parked link. It also holds what a book hides from everyone: a
`visibility: hidden` paragraph and an `aria-hidden` one. A third, **Hidden heading over a
table** (`OPS/table.xhtml`), opens with a parked heading and then a table, so the heading is
hidden labels alone on a line of no height. A second table stands between shown lines on the
section's first page, its last cell a link, and the section goes on for more than a screen. A
fourth, **Pictures and their words** (`OPS/pictures.xhtml`), holds what a book can say of a
picture: nothing, that it is decoration (an empty `alt`), or words. Each stands in a line of
text; a decorative one is also all that a link holds, and stands beside words in a link; and
two come from a file that has a title of its own, one with an empty `alt` and one with none.
After them come pictures the book keeps from assistive technology, each in a line of text:
"Ornament" with words and `role="presentation"`, "Plain ornament" with no `alt` and
`role="none"`, "Kept square" with words and `aria-hidden="true"`, "Drawn square" an inline
SVG with a title and `aria-hidden="true"`, "Quiet jump:" before a link that such a picture
with words is all of, and "Jump with an ornament", a link whose picture has
`role="presentation"`. Every word the book gives those pictures begins with "Unspoken", and
none is to be heard. Two it does not keep from it close the section: "Square shown to all",
with `aria-hidden="false"`, and "Square with a note", whose `role="presentation"` ARIA
ignores for its `aria-describedby`.
None of the section's words is one VoiceOver uses for a picture or a link, so those in a
transcript are VoiceOver's own. A fifth, **Scenes set apart** (`OPS/scenes.xhtml`), holds
rules: an `<hr>` between two paragraphs; three the book keeps from assistive technology as
ornament, before "Words after an ornament." with `role="presentation"`, before "Words after
a plain ornament." with `role="none"` and before "Words after a kept ornament." with
`aria-hidden="true"`; and one alone on a page of its own, with a last paragraph on the page
after it. None of its words is one a screen reader uses for a rule either. A sixth, **What each line offers**
(`OPS/offers.xhtml`), shows every kind of item at once, on one page and one
screen, for what VoiceOver's rotor offers on each: its heading, lines of words ("Plain words
above." and "Plain words below."), a link inside a line (**Lone jump**), a picture with words
(**Square with words**) and one with none, and a table row whose second cell is a link ("Left
cell" and "Right cell jump"). Sixty short lines follow ("Below line 01."), so the section's
first line can be shown at the top in continuous scroll. None of its words is one VoiceOver
uses for an action, a picture or a link. A seventh, **Things inside
entries** (`OPS/entries.xhtml`), holds a table whose cells hold what a cell
can besides words, one kind to a cell: a rule between two paragraphs and a formula in the
first row, a described picture and a hidden label in the second, decoration and a picture
nobody describes in the third, and a table of its own in the fourth. "Entries follow."
stands before the table and a second formula after it, in the page's own text, and the
section goes on for more than a screen. It has no heading. None of its words is one a
screen reader uses for a rule, a picture, a formula, a table or a text. An eighth, **Jumps inside a grid**
(`OPS/cells.xhtml`), holds links in the cells of a table of three rows and
two columns, after two lines of words and before sixty numbered ones. It has no heading
either. The first row has a cell
of plain words and a link of words, "worded jump", in a cell that runs on to three lines at
17 points in a 600-point window. The second has a link that is a picture with words,
"Described entry jump", and one that is a picture with an empty `alt`. The third has a link
that holds such decoration and the words "Entry jump with decoration", and a link that is a
hidden label, "Parked entry jump", before the cell's shown words. Every link goes to "Link
target reached" in the first section. None of the section's words is one VoiceOver uses for a
picture, a link, a table or a text. A ninth, **Tables
of data** (`OPS/grids.xhtml`), holds four tables, each ruled as a grid: one with a caption, a header
row and a header cell in each row, an empty cell and a cell that is a link; one whose header
cells span two rows and two columns, as two of its data cells do; one given
`role="presentation"`; and one of plain cells that only its rules mark as data. A tenth,
**A table longer than a page** (`OPS/ledger.xhtml`), has forty numbered rows under a header
row, and an eleventh, **A row taller than a page** (`OPS/tallrow.xhtml`), a
cell of 2,600 numbered words. None of their words is one VoiceOver uses for a table, so
"row", "column" and "table" in a transcript are its own. A twelfth, **Jumps at the edges of
a grid** (`OPS/edges.xhtml`), holds a table of data whose header cells are links: the rows
"Dogwood" and "Elm" are each headed by a cell that is one link and nothing else, the row
"Fir" by plain words, and the middle column by such a link, "Built", over "1912", "1947"
and a cell that is a link itself, "Relaid 1960". "Words before the routes." stands before
the table and sixty numbered lines after it. It has no heading, and none of its words is
one VoiceOver uses for a table, a header or a link. A thirteenth, **Parts below a jump**
(`OPS/parts.xhtml`), has a heading after a link on the same page, which no
other section has: every other heading opens its section or stands pages after the link
before it. It opens with plain words. A link, "upper jump", stands two lines above the
heading "Second part opens", with "Earlier words finish." between them. A second link,
"lower jump", ends the page, and the next page opens with "Middle words cease." and the
heading "Third part opens" under it, so in a spread that heading is in the column beside
the link, and in continuous scroll all of it is on one screen. A third link, "last jump",
follows the book's last heading, and sixty numbered lines follow it. Each line before a
heading ends in a word no other line has, so a word VoiceOver says of itself shows where it
took it from. None of the section's words is one VoiceOver uses for a heading or a link. A
fourteenth, **Squares inside grids** (`OPS/squares.xhtml`), holds pictures
in rows that have no words of their own. Its first table is given `role="presentation"`: a
row of two pictures nobody describes and nothing else, between the rows "Top near", "Top
far" and "Foot near", "Foot far". Its second, which begins a page of its own, is a table
of data under the header cells "Sign" and "Sense": a picture described as "Blue badge"
beside "Open", and one nobody describes beside "Shut". "Words before the squares." and
"Words after the squares." stand round the first table, "Words before the signs." and
"Words after the signs." round the second, and sixty numbered lines follow. A third table,
of data again, ends the section on a page of its own, under the header cells "Crest" and
"Rank": the words "Worn" and "daily" round a picture described as "Blue crest", beside
"High"; a header cell that is a picture described as "Blue shield" and nothing else,
beside "Low"; and a cell of decoration alone (`alt=""`) beside a cell of two pictures,
"Blue ring" and "Blue star", and no words. "Words before the crests.", whose paragraph is
the target `crests`, and "Words after the crests." stand round it, and sixty more numbered
lines follow. The section
has no heading and no link, so the book's last heading and its last link are still those
of the section before it, and none of its words is one VoiceOver uses for a table, a
picture or a group. A fifteenth, **Gaps inside grids** (`OPS/gaps.xhtml`),
holds rows that have nothing to say, as the rows that space out a table used for
layout have: a row of two cells that hold nothing, a row of two that hold decoration alone
(a picture with an empty `alt`), and a row of one cell that holds nothing and spans both
columns. Its first table is given `role="presentation"` and has one of each, in that
order, between the rows "Upper near", "Upper far"; "Middle near", "Middle far"; "Lower
near", "Lower far"; and "Last near", "Last far". Its second, which begins a page of its
own, is a table of data under the header cells "Tree" and "Tally", with the same three
rows between "Oak", "Nine"; "Elm", "Four"; "Ash", "Six"; and "Yew", "Two". "Words before
the gaps." and "Words after the gaps." stand round the first table, "Words before the
tally." and "Words after the tally." round the second, and sixty numbered lines follow.
It has no heading and no link either, and none of its words is one VoiceOver uses for a
table, a picture or a group, or for a place with nothing in it. A sixteenth, **Words hidden
in the flow** (`OPS/veiled.xhtml`), holds words that `visibility: hidden`
hides in the flow, which keep their room on the page and are read by nobody
([Hidden text](native-viewer.md#hidden-text)): "Shown words before" and "shown words after."
round "concealed words in the line" in one paragraph; a hidden paragraph, "Concealed
paragraph words." and "Concealed again.", round "Revealed words inside.", which sets
`visibility: visible` again; and "Shown words around" and "the last gap." round "collapsed
concealment", which `visibility: collapse` hides. "Words before the hidden ones." and "Words
after the hidden ones." stand round them, and sixty numbered lines follow. It has no heading
and no link, no word of it is one VoiceOver uses, and no shown word holds a hidden one, so
"concealed", "Concealed" or "collapsed" in a transcript is a hidden word read. Open it with
`--href OPS/veiled.xhtml` on a simulator and `"launch=-SampleHref OPS/veiled.xhtml"` in a
hosted session. **Math readings** (`OPS/math.xhtml`) follows it, and after it
**Words kept from listeners** (`OPS/kept.xhtml`) holds shown words the book keeps from
assistive technology with `aria-hidden="true"`
([Text kept from assistive technology](native-viewer.md#text-kept-from-assistive-technology)):
a paragraph of its own, "* Unheard stars *", after "Words before the kept ones."; "unheard
words in the line" between "Shown words before" and "shown words after."; the heading
"Harbour notes" with "unheard ornament" in it; a link of kept words alone, "unheard jump",
between "Shown words around" and "the kept jump."; and a picture that `visibility: hidden`
hides ([Hidden text](native-viewer.md#hidden-text)), described as "Unheard veiled square",
between "Shown words beside" and "the hidden square.". "Words after the kept ones." and sixty
numbered lines follow. Every kept or hidden word begins "unheard" or "Unheard" and no shown
word does, so either in a transcript is a kept word read, and no word of it is one VoiceOver
uses for a heading, a link or a picture. Open it with `--href OPS/kept.xhtml` on a simulator
and `"launch=-SampleHref OPS/kept.xhtml"` in a hosted session. The book's last section,
**Links out of the book** (`OPS/outside.xhtml`), holds links to places outside the book
([#683](https://github.com/vocaro/EPUBLib/issues/683)), each in a line of its own between
"Shown before" and "in the line.": "far site", a web page; "letter route", an email address;
and "script route", a `javascript:` link, which the reader refuses with a notice. A table
follows, "Left out cell" beside a cell that is the web page "cell far site", and then a note
reference, "noted route", to a footnote whose link is the web page "noted far site". "Words
before the routes out." opens it, and "Words after the routes out." and sixty numbered lines
follow. Every address is under `example.invalid`, which nothing answers, and no word of it is
one VoiceOver uses for a link, a table or a note. Open it with `--href OPS/outside.xhtml`;
[Links out of the book](#links-out-of-the-book) has the sessions. A second bundled book, opened with
`-VerificationBook paragraphs`, is for continuous scroll: chapters of forty, forty and six
ordinary paragraphs of forty numbered words each (`p017w23` is the seventeenth paragraph's
twenty-third), so a line in the middle of a paragraph can be told from its first, and the end
of the book is a few screens from the start of its last chapter. The first book's headings
are "Page boundary verification" (level 1), which opens it, "Link target reached" (level 2)
after the numbered paragraph, the two parked ones (level 1), each opening its section, and
"Pictures and their words", "Scenes set apart", "What each line offers", "Tables of data",
"A table longer than a page" and "A row taller than a page" (level 1), each opening its
section, and "Second part opens" (level 3) and "Third part opens" (level 4) inside the
section of parts below a jump; the sections of entries and of jumps inside a grid, between
"What each line offers" and "Tables of data", have none, and neither has the section of
jumps at a grid's edges nor the three of squares and of gaps inside grids and of words
hidden in the flow. "Math readings" (level 1) opens the section after them, and "Harbour
notes" (level 2) stands in the book's last. The second book's are "Chapter one", "Chapter two"
and "Chapter three", screens apart.
Do not import private books for this check. The fixture keeps to the shared rules for
[speech fixtures and reference views](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#speech-fixtures-and-reference-views),
the plain text view below among them.

On a Mac the same application can show AppKit's own text view in the reader's place, with
none of the reader's code: `-VerificationPlainText YES` a TextKit 2 view, as the reader's
are, and `-VerificationPlainText TextKit1` a TextKit 1 view. Its text has a link of words,
"reference link", and a link that is a picture. Following either writes "Followed" and the
link's name at the start of the text, which changes the text's value. What VoiceOver says and
does there is AppKit's and VoiceOver's doing: compare it before calling a behaviour the
reader's ([Links](#links)).

Use Xcode 27, OS 27, XcodeGen, Python 3, and a graphical Mac login. Select a signing team for
the UI-test runners and physical-device app. A [hosted Mac session](#hosted-mac-sessions) needs
neither a workstation nor a team
([where Mac sessions run](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#where-mac-sessions-run)).
Build and generate from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export VOICEOVER_TEAM_ID=YOUR_TEAM_ID
python3 scripts/make-voiceover-fixture.py
xcodegen generate --spec Examples/VoiceOverVerification/project.yml
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj \
  -scheme VoiceOverProbeMac -destination 'platform=macOS' \
  -derivedDataPath .build/voiceover/mac -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$VOICEOVER_TEAM_ID" build-for-testing
```

The fixture is deterministic and original to this repository. Generated Xcode projects,
build products, logs and result bundles are ignored by Git. Keep configuration changes in
`project.yml`.

### Mac speech capture

A Mac session takes over the machine it runs on. Run it on a hosted runner, which needs no
workstation and counts as acceptance evidence: see [Hosted Mac sessions](#hosted-mac-sessions).
A session on a workstation needs the owner's explicit authorization, and only for what a
runner cannot do: someone listening, or stepping by hand
([where Mac sessions run](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#where-mac-sessions-run)
has what such a session needs).

With that authorization, the first step of the session is to reserve the owner's screen:
`mac-foreground` in the host's device record, with the owner's approval window, as
[attended Mac sessions](https://github.com/vocaro/apple-engineering/blob/main/guides/shared-host.md#attended-mac-sessions)
shows, and `VOCARO_DEVICE_OWNER` set to the session named in the reservation. The runner checks
it before its first key and again before each step, and refuses unless that session holds the
entry, the entry is neither orphaned nor uncertain, and the approval has not ended. A refused
session sends no more steps; the runner only closes a rotor or menu the steps left open and
restores VoiceOver ([#818](https://github.com/vocaro/EPUBLib/issues/818)). Release the entry
when the session ends. A hosted runner needs no reservation.

Launch a fresh reader before each case; close previous verification instances first.

```sh
open -na "$PWD/.build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app" \
  --args -SampleFlow paginated -SampleFontSize 23
python3 scripts/run-voiceover-mac.py --timeout 240 ax:next ax:lines ax:focus \
  in line right left left lastword line nextline
```

The outer Python runner owns VoiceOver's state on the Mac: it reads, toggles and restores it
as [VoiceOver state and restoration](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#voiceover-state-and-restoration)
describes, and stops only its own process groups when the deadline expires. If VoiceOver is
not back in its original state five seconds after the shortcut, the runner prints the reason,
writes the transcript all the same with the reason in a `NOT_RESTORED` line, and exits with
status 126: VoiceOver is then still on, or still off, and is yours to put back. Close only the
isolated test reader when finished.

The probe only records, printing each new phrase as a timestamped `VOICEOVER_EVENT`, while the
runner sends its steps in order and waits `--pause` seconds after each VoiceOver command. With
`--advance-after SECONDS` it sends the next step that long after a key's first new phrase, and
waits out the pause only when no new phrase is recorded. The steps, whose keys VoiceOver
answers as [key commands](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#key-commands)
describes:

- `in`, `out`: start or stop interacting with the item in the VoiceOver cursor.
- `right`, `left`: the next or previous item; inside text, the next or previous word.
- `line`, `nextline`, `previousline`: read the current line, or move a line and read it.
- `word`, `firstword`, `lastword`: read the word, or move to the first or last visible word.
- `textstart`, `textend`: move to the beginning or end of the text (Control-Option-Shift-Home
  or End).
- `linecount`: Control-Option-F3 twice, the total and visible line counts.
- `readall`: read from the cursor onward.
- `nextheading`: VoiceOver's own move to the next heading, Control-Option-Command-H. There is
  no step for the one before; go back with the rotor's list. In pages a move to a heading on
  another page turns to that page, and VoiceOver reads the page from its top: follow the
  step with `line`, which reads the heading, and `ax:lines`, which shows the page. With
  VoiceOver's cursor on a link, reached by `nextlink`, the step goes to a heading's element
  among the text's children and VoiceOver says the level first, "heading level 2 Link
  target reached": follow it with `describe`, which says what is in the cursor. In pages
  the reader turns to a heading that is on a later page, and VoiceOver says the heading,
  the first words it says after any page turn, and the heading again. Where the reader had
  to turn or scroll for the heading it puts the insertion point on it, so `line` then
  reads the heading and `right` its first word. A heading that was on the page or on screen
  already is left as it is, and `line` and `right` read from where VoiceOver last read in
  the text: a word said straight after the heading's level and words there, the one before
  the heading, is the reader moving the insertion point
  ([#454](https://github.com/vocaro/EPUBLib/issues/454)).
- `rotor`: Control-Option-U, which opens VoiceOver's rotor: lists of what the item under its
  cursor holds, the reader's Headings among them. `listright` and `listleft` go from list to
  list, `listdown` and `listup` along one, `listchoose` (Return) moves VoiceOver to the item
  named and `listclose` (Escape) closes the rotor. Send them only while the rotor is open:
  otherwise the reader takes an arrow as a page turn. The Headings list opens on its first
  item, the book's first heading, wherever VoiceOver's cursor is. Where the rotor says "No
  items in Heading menu", as it did on a page with no heading while a page's rotor held that
  page's headings alone, `listchoose` chooses nothing and the rotor stays open. The runner
  closes a rotor before it restores VoiceOver. After the
  steps of a session that sent `rotor` and no `listclose` after it, the runner sends Escape
  itself, writes `STEP listclose, sent by the runner in case the rotor is still open` and
  waits one pause; a session stopped before the end of its steps gets the same key as the
  runner cleans up. Where `listchoose` had closed the rotor, the reader takes that Escape and
  does nothing with it: VoiceOver said nothing and stayed on its line.
- `activate=LABEL`: Control-Option-Space, sent only if one of VoiceOver's last two phrases
  contains LABEL, as in `"activate=Next Page"`. Without a label it is sent whatever was said.
- `nextlink`, `previouslink`: VoiceOver's Find Next Link and Find Previous Link,
  Control-Option-Command-L and the same with Shift. They move to a link of the text under the
  cursor and name it.
- `describe`: Control-Option-F3 once, what is in the VoiceOver cursor. `attributes`:
  Control-Option-T, the text attributes there.
- `tracking`: Control-Option-Shift-F3, which turns cursor tracking off, and on again:
  whether the keyboard focus goes with VoiceOver's cursor. A session that turns it off ends
  with the step again.
- `actions`: Control-Option-Command-Space, VoiceOver's Actions menu, which holds the actions
  of the item under its cursor. `listdown` and `listup` say each one, `listchoose` performs
  the one last said, and `listclose` closes the menu. `"listchoose=show menu"` sends Return
  only if one of VoiceOver's last two phrases contains the label, as `activate=LABEL` does.
  On a column and inside its text the menu holds the
  reader's two page actions around AppKit's own, in VoiceOver's order: "Previous Page",
  "show menu", "Next Page", and in continuous scroll "Scroll Backward", "show menu", "Scroll
  Forward". So `actions listdown listdown listdown "listchoose=Next Page"` turns the page
  and `actions listdown "listchoose=Previous Page"` turns it back. On the sample's group with
  its controls embedded VoiceOver said nothing and opened no menu: the list keys after it went
  to the reader, where Down Arrow moves the insertion point. The runner closes a menu a
  session can have left open as it does a rotor, with `STEP listclose, sent by the runner in
  case the Actions menu is still open`.
- `columnheader`, `rowheader`: Control-Option-C and Control-Option-R, which inside a table
  say the header of the cell's column and of its row. `readcolumn` and `readrow` send each
  twice, for the rest of the column and of the row. `rowcolumn` and `dimensions` are
  Control-Option-Shift-T once and twice: in the reader's tables VoiceOver said the attachment's
  character at the first and nothing at the second (macOS 27.0.1). See
  [Tables on Mac](#tables-on-mac).
- `nexttable`, `previoustable`: VoiceOver's Find Next Table and Find Previous Table,
  Control-Option-Command-T and the same with Shift. They were sent to Safari only, where
  each moves to a table of the page and says it as arriving at it does; see
  [Safari on Mac](#safari-on-mac).
- `pagedown`, `pageup`: the reader's own page keys, without VoiceOver modifiers.
- `ax:STEP`: a step of the observer described below, through the accessibility API.

With `--safari` the session is of Safari in place of the reader: open Safari at the page
first, once. The runner then sends its keys to Safari and to nothing else, and gives the
observer Safari's process, whose `ax:` steps are those of a web page
([Safari on Mac](#safari-on-mac)). `--xctest-values` is refused with it.

The runner makes the checks of
[speech capture and the key driver](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#speech-capture-and-the-key-driver)
before every key, with Safari in place of the reader in a session of Safari. Each run writes
`mac-STAMP.transcript.txt` beside its log, observer events and result bundle in
`.build/voiceover/results/`: the steps, heard phrases, value and layout events and fresh
column states merged by time, with `OTHER_TESTS` lines naming unit-test hosts of other
sessions. Read the transcript against the visible text, starting with its first phrases.

VoiceOver enters a column at its insertion point, and a page turn resets that to the first
line. A place shown, as a link followed, puts it at the start of the place's line instead
([A link's target in pages](#a-links-target-in-pages)). Start a case with a turn and
`ax:focus`, never a click. Eight `left` steps from the
left column, nine from the right, reach **Next Page** in the sample's control strip; eight
`right` steps return from it to the left column. **Previous Page** is one step further.

`"ax:press=Use Toolbar"` moves the sample's controls to the window's toolbar, outside the group
that holds the columns. From the left column, `out out`, five `left`, `in` and six `right`
reached Next Page there in three sessions on a reader with the fix of #337; on one without
it the same keys went elsewhere twice. `activate=Next Page` stops such a session.

A table's row is one character of its page's text, and each of its cells on screen is a text
area of its own. Moving by word (`right`) VoiceOver stops on a row of a table that is not
data and says its cells' words and "group", "First cell, Second cell group"; a row of a
table of data says its words and "table" ([Tables on Mac](#tables-on-mac)). `in` on a
group says "In First cell, Second cell group 2 items text First cell", and puts
the cursor on that cell; `right` goes to the row's next cell; `in` again reads inside the
cell, by word and by line as in the page's text; `out` leaves the cell, and a second `out`
the row. With the cursor at the cell's first word, `firstword` says "beginning of text".
Until 2026-10-13 such a row was called "Table row", and the records from before say "Table
row group" and "In Table row group 2 items text" where a row's words are now.

A session can open with VoiceOver's cursor on a control, on the reader's group or already on
the text, and what VoiceOver keeps of a column depends on how it got there. For a case in which
VoiceOver leaves a column and comes back, bring it to the column by a focus change from
somewhere else, `ax:focus=search ax:focus=0`: when it was on the text from the start, it came
back at the page's first line even on a reader with the fault of
[#337](https://github.com/vocaro/EPUBLib/issues/337).

Use a 600-point window for one column and 1100 points for two (`ax:width=600`),
`-SampleFontSize 17` and `23`, and `ax:larger` or `ax:smaller` for a change while the reader is
open. Take the column count and visible ranges from the `STATE` and `LINE` lines, because
wrapping and viewport height change the numbered boundaries.

### Page actions and value notifications

Observe the real application's accessibility transport with the Mac observer, alone or as
the runner's `ax:` steps:

```sh
VOICEOVER_READER_PID=$(pgrep -x VoiceOverVerificationMac)
VOCARO_AX_ALLOWED_BUNDLES=org.epubreaderlib.voiceoververify.mac \
xcrun swift "$(python3 scripts/eng source voiceover-ax-observer.swift)" "$VOICEOVER_READER_PID" 60 \
  lines next lines previous larger smaller width=600 width=1100 \
  > .build/voiceover/ax-events.log
```

The observer accepts only the verification reader's bundle identifier. Its steps, its output
lines and how to read them are in the shared
[accessibility observer](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#accessibility-observer).
With this reader:

- `next`, `previous` press the page buttons, found by label or help rather than index.
- `"ax:press=Use Toolbar"` moves the sample's controls from the reader's group to the window's
  toolbar, and the segments of Reading Mode, `"ax:press=Continuous Scroll"` and
  `ax:press=Paging`, change the flow while the reader is open.
- `larger`, `smaller` choose the Appearance menu's text-size items.
- `focus=0.2` gives the keyboard focus to a table cell, by the name `links` prints. That does
  not bring VoiceOver into the cell: its `in` then entered the page's text. See [Links](#links)
  for the way in.
- In `links`, a table row is one run, a group that holds a text area for each of its cells on
  screen. Each cell follows its column with a name of its own, `0.3` for the first column's
  fourth, and the same lines with `CELL` before them: `CELL 0.3 VALUE`, and `CELL CHILD` and
  `CELL LINK` for what the cell's own text gives.
- `actions=all` prints every element of the window, not only those `actions` prints.
- `"ax:action=Next Page"` is an action a column's text area has in pages.
  `"ax:action=Scroll Forward"` in continuous scroll gives -25200 though the view scrolls: read
  the `STATE` after it.
- `"ax:caret=Bare jump"` puts the insertion point before those words, so `in` then starts on
  that line and `right` reads the word.
- `focused` prints `FOCUSED AXTextArea COLUMN` for a column, `FOCUSED AXTextArea CELL` for a
  table cell's text area, a control, or `FOCUSED AXWindow` where the window itself holds it.
  VoiceOver gives the focus to each text area it moves to, a cell's among them. A cell
  that is one link holds its text area inside the link, and the observer calls that text
  area a column: `FOCUSED AXTextArea COLUMN VALUE Reopened 1978` is the cell's.

`--xctest-values` adds XCTest's own snapshot of each column to the transcript whenever it
changes. Use it with `ax:` steps only. The runner stops a session, with exit status 125, as
soon as VoiceOver has named XCTest's **Automation Running** banner; only `--xctest-values` with
`ax:` steps alone is exempt. Snapshots re-queried for each read matched the observer after
every native page turn, text-size change and resize, with and without the reader's
notifications.

### Continuous scroll

In continuous scroll one text area holds the whole book. VoiceOver on the Mac enters it at its
insertion point
([VoiceOver enters a text view at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point)),
which the reader keeps on the first line on screen (see
[the native viewer](native-viewer.md), "Continuous scroll"). Launch the reader in that flow and
compare what VoiceOver says on entering with what is on screen:

```sh
open -na "$PWD/.build/voiceover/mac/Build/Products/Debug/VoiceOverVerificationMac.app" \
  --args -SampleFlow scrolled -SampleFontSize 23
python3 scripts/run-voiceover-mac.py --timeout 240 --pause 4 ax:width=600 ax:next ax:next \
  ax:focus in line nextline nextline pagedown line nextline out right ax:next left in line
```

There the observer's `next` and `previous` press Scroll Forward and Scroll Backward. Every
`STATE` line gives `VISIBLE`, the text area's visible characters, and `ENTRY`, the line of its
insertion point, and the transcript carries each `AXSelectedTextChanged`, so the insertion
point can be followed beside the speech.

1. Scroll before the first `in` of a session. VoiceOver keeps a text cursor of its own once
   it has been in a text area, so only a first entry shows where the insertion point takes it.
   The phrase after `in` is the `ENTRY` line of the `STATE` before it, the first on screen.
2. `nextline` reads the following lines in order while `SELECTION` follows VoiceOver. The
   first one after entering repeats the rest of the entry line, as in paging.
3. `pagedown` while interacting moves `SELECTION` to the new first line; `line` then reads it.
   So does Scroll Forward chosen in the Actions menu, and so does either made straight after
   `in`, before VoiceOver has moved in the text. Each step shows two `AXSelectedTextChanged`
   with the one `SELECTION`: AppKit's, and the reader's second notice, which is what brings
   VoiceOver's cursor along there. With one notice VoiceOver named the line it had entered at
   ("text  word:  Read"), `SELECTION 0,0` followed, and `line` read the book's first line:
   the step was undone ([#473](https://github.com/vocaro/EPUBLib/pull/473)).
4. `out`, `right` to leave the text, a scroll step, `left` and `in`: VoiceOver enters at the
   new first line. Each of the reader's own moves shows as `AXLayoutChanged`.

`VISIBLE` is AppKit's own account and counts whole paragraphs: the fixture's 1,200-word
paragraph is visible from its first character while any of it is on screen, and VoiceOver's
first and last visible word, and a text cursor it brings back into view, go by that. The text
area's lines are the whole book's, so a `STATE` read is slow in a long book; the fixture has
269 at this size.

On an iPhone or iPad VoiceOver walks the scroll view's accessibility elements instead, and the
reader lists the lines on screen and the fifty after them, with the fifty before the screen
as well while VoiceOver's cursor is in the text (see [the native viewer](native-viewer.md),
"Continuous scroll", for why fifty). Run the probe (see "Physical iPhone and iPad") in that
flow, on the book of ordinary paragraphs, by adding to its command:

```sh
TEST_RUNNER_VOICEOVER_FLOW=scrolled TEST_RUNNER_VOICEOVER_BOOK=paragraphs \
TEST_RUNNER_VOICEOVER_FONT_SIZE=17 \
TEST_RUNNER_VOICEOVER_STEPS='activate=Scroll Forward,activate=Scroll Forward,wait=2,visible,screenshot,forward=9,visible,screenshot,forward=30,visible,backward=44,visible,screenshot'
```

1. Two scroll steps end in the middle of a paragraph. The first `visible` gives the first and
   last lines on screen. Nothing above them is listed; the fifty lines after them are, and
   are counted as outside the window.
2. Eight moves forward from Scroll Forward cross the sample's other controls and the ninth
   enters the text. Its phrase is the first line on screen, not `w01` of that line's
   paragraph, and the screenshot after it shows the same lines as the one before: coming in
   scrolled nothing.
3. The second `visible` counts fifty more lines, those before the screen, and says how many
   are outside the window.
4. The moves forward give every line once, in order, while the view follows; the moves back
   pass the line VoiceOver came in at and go on above it. A phrase repeated, a line missing,
   or a control's name among them is a failure.
5. `backward=1` straight after coming in returns to the control before the text. A touch on
   a control (`touch=Bookmark`) takes the cursor out, and `visible` then lists nothing above
   the first line on screen; the next move forward comes in at that line.
6. `activate=Contents,activate=Chapter two` moves the reader with the cursor on a control, and
   `point=0.5:0.8` touches a line directly: VoiceOver reads the line under the finger.
7. Straight after a menu closes VoiceOver asks for fifty items at once and reads through
   them. `activate=Contents,activate=Chapter two,wait=2,visible,forward=5,forward=62,visible,backward=72`
   comes into the text at the chapter's heading on the fifth move and must go on past the
   last line that was on screen when the menu closed, a line at a time. "Vertical scroll
   bar" among the lines is the failure of
   [#339](https://github.com/vocaro/EPUBLib/issues/339). On an iPad run it on its side as
   well, with `rotate=landscape` first and `rotate=portrait` last.
8. `touch=LABEL` on an item below the reader and `backward=30` come into the text from below:
   the scroll bar, then the last line that was on screen, then every line above it in order,
   on past the top of the screen. Run it where the view has room to go back, after two
   scroll steps, and at the end of the book
   (`activate=Contents,activate=Chapter three,wait=2` and three scroll steps). "Bookmark"
   straight after the scroll bar, or after one line, is the failure of
   [#367](https://github.com/vocaro/EPUBLib/issues/367): as the cursor went to the scroll
   bar UIKit took the view back 88 points, which it no longer does (step 10). The line after
   the scroll bar is
   the last line in the reader's own view. `visible` gives a later one as the window's last:
   with the cursor on a control before the text it counts every listed line that lies inside
   the window, and the first lines listed after the screen lie under the sample's footer.
9. No line of plain text has "Actions available" after it, and `flick=down` with the cursor on
   one reads no action: it steps by the rotor's own setting, a character of the line on a
   simulator. An iPhone's lines are short enough to show the whole phrase in the 64
   characters a transcript keeps. In the first book the picture's own line says it, and
   `flick=down` there reads "Inspect Image: Blue verification square" and then "Activate".
10. At the end of the book (`activate=Contents,activate=Chapter three,wait=2` and scroll
    steps until Scroll Forward is dimmed) put the cursor on a line near the last, with
    `touch=p086w36` on an iPad at 23 points or `point=0.5:0.6` on an iPhone, and move
    forward past the last line, back and forward again (`forward=12,backward=8,forward=10`
    on the iPhone): the book's last line, "Vertical scroll bar", then the item below the
    reader, where VoiceOver stays; back, the scroll bar, the last line and the lines above
    it in order; forward, the same lines, the scroll bar and the item below. The first line
    on screen straight after the scroll bar, or a jump up the screen one move after coming
    back to the last line, is the failure of
    [#342](https://github.com/vocaro/EPUBLib/issues/342). Then touch the bar itself, at the
    reader's right-hand edge (`point=0.955:0.6` on an iPhone 17 Pro, `point=0.982:0.6` on
    an iPad upright): `backward=4` reads the last line listed and the lines above it, where
    it read "Bookmark", and `forward=1` from the bar reads the item below the reader. Do
    the same after two scroll steps, where the last line listed is the last in the reader's
    view. Nothing scrolls as the cursor goes to the bar: at the end of the book the bar reads
    100%, where it read 99% while the view went back for it. `flick=down` on the bar takes
    the view a tenth of the way through the book and reads the new value, with the cursor
    still on the bar, and `backward=5` from there reads the last line then on screen and
    the lines above it in order. The second of those lines again at every further move is
    the failure of the adjustment in
    [#342](https://github.com/vocaro/EPUBLib/issues/342): VoiceOver had taken the list to
    start there. A line of text read at the flick itself is the harness's: on a busy Mac the
    swipe was taken for a touch and moved the cursor to the line under it.
11. Have the reader move by something VoiceOver did not do
    (`-SampleStepAfter`, under "Physical iPhone and iPad"). With the cursor
    on a line, `touch=p001w01,listen=30,forward=3,backward=4` and the step at 30 seconds:
    `listen` records the first line of the new screen, which VoiceOver reads by itself, and
    the moves go on from that line and back past it. A `listen` that records nothing, with
    the moves reading the lines after `p001w01 …`, is the failure of
    [#428](https://github.com/vocaro/EPUBLib/issues/428): VoiceOver stayed on its line and
    the reader went back to it. With the cursor on a control and fifty items held,
    `activate=Contents,activate=Chapter one,wait=1,forward=5,forward=3,touch=Scroll Forward,listen=40,forward=9,forward=4`
    and the step at 55 seconds: the ninth move from Scroll Forward gives the first line of
    the new screen. "Chapter one" there is the failure. The moves before the touch are
    needed: VoiceOver asks for fifty at its first move after the menu, and a touch straight
    after the menu has it ask for two. In place of the timed step a simulator can use
    `activate=Scroll Forward`, and `activate=Verification link` in the first book for the
    cursor on a line, because its double tap is a plain touch that VoiceOver knows nothing
    of ("Simulators"). On a device those two read right with the change and without it.

Drive at least one session with `flick=right*20` and `flick=left*30` in place of `forward`
and `backward`: those are VoiceOver's own gestures for the next and previous item, where the
others are the test service's moves. They take about six seconds each under XCTest
([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).

### Links

On a Mac a link is found, named and followed through elements the reader gives VoiceOver
([the native viewer](native-viewer.md), "Links for VoiceOver on Mac"). VoiceOver's own part
was heard first, in AppKit's text view (`-VerificationPlainText`), and is recorded in
[links in an AppKit text view are children, not places](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#links-in-an-appkit-text-view-are-children-not-places);
a session on links is read against it. Of the hint VoiceOver gives after a link's name, "You
are currently on a hyperlink, inside of a text area. To click this link, press
Control-Option-Space", the probe records the first 64 characters. For the reader's text the
rotor lists the book's headings.

In continuous scroll `nextlink` from the last link on screen goes on to the book's next
link, below the screen, and so through the book. The reader shows that link and puts the
insertion point on it, and VoiceOver says a word and then the link, role first: "words."
and "hyperlink Parked link to the target", the word being the last one before the link,
with `AXLayoutChanged` and `SELECTION` at the link between them. `right` then reads the
link again and goes on from it, and `line` reads its line. Where that link is in a
table's cell the insertion point is on the cell's row, and `right` says the row: "Table
row group" when this was heard, and the row's words and "group" since rows are called by
them ([Tables on Mac](#tables-on-mac)), which was not heard here again. Only the links
with nothing on screen are heard that way: for the others on the
screen the reader went to, `nextlink` says the name and "hyperlink" as on a page, and
`right` reads on from where VoiceOver last read. Past the book's last link it does what
it does on a page. With `tracking` first (cursor tracking off) VoiceOver says the link
below the screen by its name, scrolls to it itself, and `right` reads on from where it
last read.

`ax:links`
([accessibility observer](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#accessibility-observer))
prints what the text gives for its links before anything is said: each link once
as a `CHILD`, called by its words and never by U+FFFC, with `AXPress` among its actions; and
in the `LINK` lines the same element as the link of its characters and, where the link has an
attachment, a link element as that character's attachment. The text's headings are `CHILD`
lines too, `AXHeading` with the heading's words as `LABEL`, each where it stands among the
links: those on the page or on screen, and last the book's next heading, which is below the
screen in continuous scroll and on a later page in pages. In continuous scroll the links end
the same way, with the book's next link below the screen, or with the links of the next
table row that has one. A heading's and a link's child end in `FOCUSABLE`
([VoiceOver focuses only an element that reports its focus](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-focuses-only-an-element-that-reports-its-focus)).
`ax:caret=WORDS` before `ax:focus in` starts VoiceOver on a link's line, so
a few `right` steps reach it. After a link is followed the transcript has `AXValueChanged`
with the page that holds the target, in the fixture the one with "Link target reached".

A link in a table cell is in a text of its own, inside its row. Moving by word in the
page's text VoiceOver stops on a row and says its cells' words and "group": "Plain first
entry., Before the worded jump after it, and then en…", the 64 characters a phrase has.
`in` there interacts with the row: "In", the row's words, "group 2 items" and the first
cell's text, of which a transcript has the first 64 characters too.
`right` moves to the next cell and a second `in` enters the cell, where `right`, `line`,
`nextline`, `nextlink` and `activate` do in the cell's text what they do in the page's.
`"ax:caret=grid."` puts the insertion point one word before the fixture's table of links,
so after `ax:focus=search ax:focus=0 in` two `right` steps reach its first row and each
further one the next row. In continuous scroll enter with `ax:focus in`: after the focus
change from the search field the first `in` there said the book's first line, and a second
was needed. `ax:focus=0.2` gives a cell keyboard focus and does not bring VoiceOver into it.
`ax:links` prints each cell's own links as `CELL CHILD` and `CELL LINK` lines, and the
page's `CHILD` lines hold the links of the cells on screen among the page's own.
`nextlink` from the page's text goes through all of those. VoiceOver's place in the page's
text does not move with it, so `right` after one of a cell's links reads on from the word
VoiceOver had reached before the table. A cell's link that the reader had to scroll to in
continuous scroll is the exception: the insertion point is then on its row. In the runs on links `line` said nothing with
VoiceOver's cursor on a cell's last word or past it, in main's reader as with the cells'
own elements. A cell has a line there since: see the record of Read Line in a table cell.

What VoiceOver says of a link as it reads depends on its
[link verbosity](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#link-verbosity):
every hosted run writes it to `runner.txt` as `LINK VERBOSITY`, and the workflow's `links`
input chooses it.

#### A link's target in pages

The fixture's **Verification link** goes to "Link target reached", the first section's last
heading, before one short paragraph, on its last page and below that page's first line. A followed
link is how a session goes to a place in the middle of a page: the observer cannot type into
the search field, and `press=LABEL` presses buttons only. Where the heading is depends on the
window and the text size, so take it from the `LINE` lines of `ax:lines` after the link. On
the runner, at 600 points and 17 it is the third line of a page of four; at 1100 and 23 the
sixth of seven in the left column, the right one empty; and at 1100 and 28 the fifth of seven
in the right column, which is the case of a place in the column beside the one VoiceOver is
in. Each way in is a session:

```text
width=600 text_size=17 "ax:caret=Verification link" ax:focus=search ax:focus=0 in line "activate=Verification link" ax:lines line nextline
width=600 text_size=17 ax:focus=search "ax:follow=Verification link" ax:lines ax:focus=0 in line nextline
width=1100 text_size=28 ax:focus=search ax:focus=0 "ax:follow=Verification link" ax:lines ax:focused in line nextline
```

The first follows the link with VoiceOver's own Control-Option-Space from inside the text,
the second presses it with VoiceOver on the search field, away from the reader, and the third
with VoiceOver resting on the left column without interacting with it. `ax:focused` says which
column then has the keyboard focus, and `STATE` gives each column's `SELECTION` and `ENTRY`.
Since [#383](https://github.com/vocaro/EPUBLib/issues/383) `line` reads "Link target
reached" after each of them, and `in`, where there is one, says "In text Link target
reached"; before, both read the page's first line. With the heading in the right column the
keyboard focus goes to that column, and VoiceOver is on the column and out of the text it was
in: `line` reads the heading there, but `nextline` does not move by line until `in`. From
the start of the heading's line the first `nextline` records nothing and the second reads
"This is the end of the numbered paragraph.": VoiceOver's moves by line leave its insertion
point at a line's end, so one from a line's start reads that line again, and the probe
records a phrase only when it differs from the one before. The sessions on `main` and on the
change are [on the issue](https://github.com/vocaro/EPUBLib/issues/383#issuecomment-6277358412).

The reader opened at the heading is a session of its own:
`"launch=-SampleHref OPS/body.xhtml#link-target"` shows it, and the session's resize to its
width is a relayout straight after the place is shown. `ax:larger` builds the text again at
a larger size, another relayout, and `nextline` before it is VoiceOver moving the insertion
point from the place:

```text
width=600 text_size=17 "launch=-SampleHref OPS/body.xhtml#link-target" ax:lines ax:focus=search ax:focus=0 in line
width=600 text_size=17 "launch=-SampleHref OPS/body.xhtml#link-target" ax:focus=search ax:focus=0 in line nextline ax:larger ax:lines ax:focus=search ax:focus=0 in line
```

Since [#594](https://github.com/vocaro/EPUBLib/issues/594) the first session's `in` says "In
text Link target reached" and `STATE` gives `SELECTION 126,0`. Before, the resize put the
page's first line back, and `in` read it. In the second, `nextline` moves the insertion point
to the end of the heading's line, and a relayout after that enters at the first line. On the
runner at 600 points, though, the size `ax:larger` gives starts a page with the heading, so
that page's first line is the heading, and the session cannot tell the two rules apart: take
the heading's line from `ax:lines` before reading anything into it. The sessions are
[on the issue](https://github.com/vocaro/EPUBLib/issues/594#issuecomment-6278967907).

#### Links out of the book

The reader asks before it opens a web or email link outside the book
([Security](native-viewer.md#security), [#683](https://github.com/vocaro/EPUBLib/issues/683)).
What VoiceOver reads of the question on iPhone and iPad, and where its cursor goes after it,
is read on simulators, in the fixture's **Links out of the book**: links in the text, then one
in a table's cell and one in a note's popover, each answered Cancel, so nothing is opened:

```sh
python3 scripts/run-voiceover-simulator.py --href OPS/outside.xhtml \
  --steps 'touch=far site,activate=far site,listen=4,forward=2,activate=Cancel,listen=4,touch=letter route,activate=letter route,listen=4,activate=Cancel,listen=4,touch=script route,activate=script route,listen=3,find=This reader opens only,touch=Left out cell,choose=Follow Table Link: cell far site,doubletap=Left out cell,listen=4,activate=Cancel,listen=4,touch=noted route,activate=noted route,listen=3,touch=noted far site,activate=noted far site,listen=4,forward=2,activate=Cancel,listen=4'
```

`listen=4` after each activation records what VoiceOver says of the alert by itself, the
question and the address, and `forward=2` its buttons; `listen=4` after Cancel records where
the cursor went back to ([#793](https://github.com/vocaro/EPUBLib/issues/793)). VoiceOver's
own log beside the transcript has everything it said in between, which a transcript can miss.
`find=` says whether the notice for the `javascript:` link is on screen. A simulator's
activation is not evidence that VoiceOver
activates the link ([Simulators](#simulators)); that needs an iPhone or iPad. What VoiceOver
on Mac says of the sheet needs a [hosted Mac session](#hosted-mac-sessions), such as one that
presses the link with VoiceOver on the search field, `ax:follow` as under
[A link's target in pages](#a-links-target-in-pages), and records what is said after it:

```text
width=600 text_size=17 "launch=-SampleHref OPS/outside.xhtml" ax:focus=search "ax:follow=far site" line
```

### Tables on Mac

On a Mac a table of data is a table at each of its rows: the text gives AppKit's table as
the element of each row's character ([the native viewer](native-viewer.md), "Data tables").
A session on tables is read against these, which are VoiceOver's own part (macOS 27.0.1);
what they show of VoiceOver itself is in
[on the Mac VoiceOver meets a table only at an attachment character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#on-the-mac-voiceover-meets-a-table-only-at-an-attachment-character)
and the articles after it:

- Moving by line or by word VoiceOver says a row's words and "table". A row of a table that
  is not data says its cells' words and "group": "Left side, Right side group", "Lower
  left, Lower right group". The words are the reader's label, in column order with a comma
  between cells, and "group" is VoiceOver's. A phrase in a transcript is cut at 64
  characters, so a long row's has no "group" in it.
- `in` goes into the table at that row and says the first cell with its headers: "In Birch,
  1934 table Station Birch". `right` and `left` move along the row and on into the next,
  `nextline` and `previousline` (Control-Option-Down and Up) along the column. VoiceOver
  says a header when it has changed since the cell before, then the cell: "Opened 1934",
  "Cedar Forty metres". An empty cell is "empty cell". Where it cannot go on, at the table's
  last row, at a page's first or last, or moving down inside a cell that spans, it says the
  cell and "column 2, row 41".
- `columnheader` and `rowheader` say the header of the cell's column and of its row,
  "Depth", "Birch". Where nothing heads them VoiceOver says the number: on the first table's
  header row "Depth column 3, row 1" for a move and "row 1 of 4" for `rowheader`, and on a
  row's own header cell "row 3 of 4". A column under two header cells is headed by both,
  "Hours, Leaves Nine", and so is the lower of the two itself, "Hours, Leaves Leaves".
- A session in which VoiceOver starts again in the middle ("ERROR 3" and then "VoiceOver on
  VoiceOverVerificationMac…") is one in which it quit. It did so when a cell named header
  cells of its own, most often within eight headers at two seconds a key
  ([#483](https://github.com/vocaro/EPUBLib/issues/483);
  [a cell that names its own header cells makes Mac VoiceOver quit](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-cell-that-names-its-own-header-cells-makes-mac-voiceover-quit)).
  A session of moves across rows
  with `columnheader` after each (`pause=2`) is the test for it.
- `in` on a cell goes into its text, "In text 1934", where `right` moves by word; `out`
  comes back to the cell, and `out` again to the row's line in the text.
- `actions` on a cell says "Actions menu" and its count, and `listdown` each of Select Cell
  Text, Follow Link: WORDS and Inspect Image that the cell has.
- A cell whose words are one link and nothing else is said with "hyperlink" after its
  words, "Opened Reopened 1978 hyperlink" along the row and "Cedar Reopened 1978 hyperlink"
  down the column, and its hint says "You are currently on a hyperlink cell". `describe`
  says "Reopened 1978 hyperlink hyperlink cell is in the VoiceOver cursor": what the cell
  holds, then VoiceOver's name for such a cell. `actions` says three items, the third
  VoiceOver's own "press", and `activate` follows the link. `in` says "In hyperlink
  Reopened 1978 text Reopened 1978" and `in` again "In text Reopened 1978", where `right`
  moves by word; `out` says "Out of text" and `out` again "Out of hyperlink Reopened 1978",
  which is back on the cell.
- A header cell that is one link is said the same way, with its place after it where
  nothing heads it: "Built hyperlink column 2, row 1" along a header row, "Elm hyperlink
  column 1, row 3" down a column of row headers, "Route Dogwood hyperlink" along its own
  row. The cells it heads say its words and no "hyperlink", "Dogwood 1912", and so do
  `columnheader` and `rowheader`, "Built" and "Dogwood". A cell said without its header
  there, "1912", with "column 2 of 3" at `columnheader`, is a header cell whose link has no
  title: VoiceOver reads a header cell by what each thing it holds is called
  ([Mac VoiceOver reads a header cell by what it holds](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#mac-voiceover-reads-a-header-cell-by-what-it-holds)).
  A header cell's name said before the cell itself, "Elm Elm hyperlink", is a header that
  the table gives as something other than the cell. On a cell of a header row
  `columnheader` says the row's words, "Route, Built, Length".
- After a link is followed in pages, `describe` says where VoiceOver is: "text is in the
  VoiceOver cursor Line 1" on the new page's text area, where `in` goes into the page's
  first line, and "Open EPUB… button is in the VoiceOver cursor" where it has left the text
  for the window's first button ([#485](https://github.com/vocaro/EPUBLib/issues/485)).
- `in` on a row's group says "In", the row's words, "group 2 items" and "text" with the
  first cell's words: "In Lower left, Lower right group 2 items text Lower left". `right`
  and `left` move among the row's cells, "text Lower right"; `in` on one goes into its
  text, "In text Lower right", where `right` moves by word; `out` comes back to the cell,
  and `out` again says "Out of Lower left, Lower right group".
- After `out` VoiceOver is on the table it left. `nextline` reads the next line, and `in`
  there goes back into the table left, at the cell it was on. A row group of a table that
  is not data does the same. Move by word (`right`) to the next row before `in`. After
  `out` of a group reached by moving forward, `right` says the next row. Of one reached by
  moving back, the first `right` says that row again and the second the next row, which
  was heard without "group": "Third cell, Fourth cell".
- A page turned straight after `out`, with VoiceOver's cursor on the row's element, by
  `ax:next`, `pagedown` or `"ax:action=Next Page"`: VoiceOver says "text", from a row group
  with the new page's first line after it, and `describe` says "text is in the VoiceOver
  cursor". From either, `line` and `right` read the new page's first line and that line's
  first word, or a row's words twice. That is VoiceOver in the text, on the row's element
  of the page before ([the native viewer](native-viewer.md), "Data tables", "Pages"). In a
  spread the turn says "2 updated items", from a row group with the first line after it,
  and from a table of data with the new first row's words before it. A turn that says
  "empty", with `describe` "empty  text is in the VoiceOver cursor", is a departed table
  of data that gives no rows, and `describe` "text 3 columns, 41 rows" is one that gives a
  row and a column. Set it beside the two others: on the text area and not in it `describe` says "text is in
  the VoiceOver cursor Line 1" and `right` goes to the next item of the window, and on a
  line of the text "Line 1  word: …", with `right` reading on in the page. A turn from a
  line reads the new page's first line itself, "text  word: …". Before
  [#485](https://github.com/vocaro/EPUBLib/issues/485) a row group's turn left the text
  for the window's first button, "Open EPUB… button is in the VoiceOver cursor", and a
  table's left VoiceOver on the text area, and then said "empty" until a departed table
  gave one row of nothing. `ax:focused` before the turn shows where the keyboard focus
  is: VoiceOver gave it to a row group's cell, `FOCUSED AXTextArea CELL`,
  and to no cell of a table of data, whose text areas it goes into only from the cell.
  After the turn it is the column's, `FOCUSED AXTextArea COLUMN`, where it was `FOCUSED
  AXWindow`. The sessions, what was tried against the table's "empty", and the VoiceOver
  code that made it, are on
  [the issue](https://github.com/vocaro/EPUBLib/issues/485#issuecomment-6270877949) and
  [after it](https://github.com/vocaro/EPUBLib/issues/485#issuecomment-6272726811).
- The probe records a phrase once
  ([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)):
  a second row that says what the row before said leaves no line in a transcript. Every row
  of a table that is not data did while it was called "Table row"; now only two rows of the
  same words do.
- A row of a table that is not data whose cells show pictures nobody describes and no
  words has no name, and VoiceOver says what it holds: "text image text image group" for
  a row of two, by line, by word and with `readall`. `in` says "In group 2 items text
  image", `right` "text image", `in` on a cell "In text image" and `right` there
  "image", and the two `out` "Out of text" and "Out of group". In continuous scroll
  `describe` straight after that `out` says "group is in the VoiceOver cursor", and an
  Actions menu closed there leaves "group" alone, where a page has the row's whole
  phrase. Until 2026-10-13 such a row was "Table row group" as the others were.
- `actions` while VoiceOver reads the text is the text area's menu, on a row's line as
  on a line of words: "Actions menu 3 items", the two page actions round "show menu",
  and on closing "text  word:" and the row's phrase. A row's own actions, Inspect Image
  for each of its pictures, are in the menu when VoiceOver's cursor is on the row's
  group, which it is after `in` and `out`. For the row of two pictures that is "Actions
  menu 6 items" on a page, the row's two and then "show menu" and "Inspect Image" for
  each cell's text, and "Actions menu 2 items" in continuous scroll. Two items of one
  name that follow one another leave one line in a transcript.
- A cell of a table of data that shows a picture and nothing else is said by its header
  and the picture's words with "image": "In Blue badge, Open table Sign Blue badge image",
  "Blue badge image" down a column, and for a picture nobody describes "Sign image cell"
  and "image cell". `describe` says "Blue badge image image cell is in the VoiceOver
  cursor", what the cell holds and then VoiceOver's name for such a cell, or "image cell is
  in the VoiceOver cursor". `actions` there has "Inspect Image: Blue badge" and "Select
  Cell Text", or "Inspect Image" alone, and `"listchoose=Inspect Image: Blue badge"` after
  a `listdown` opens the inspector, which `ax:actions=all` shows by Zoom Out, Zoom In, Fit,
  Close and an image called "Blue badge". `in` says "In Blue badge image image cell Blue
  badge image", or "In image cell image", and goes nowhere: the next `right` is the next
  cell of the row, and one `out` leaves the table. Until 2026-10-13 such a cell held a
  text area: a transcript had "Sign ￼", "￼ cell" and "In text Blue badge image".
- A cell of two pictures is "Rank Blue ring image, Blue star image", and `describe` adds
  "cell 2 items". `in` goes to the first, "In Blue ring image, Blue star image cell 2
  items Blue ring image", `right` to the next, "Blue star image", where `actions` has that
  picture's Inspect Image alone, and `out` comes back to the cell. A cell of decoration
  alone is "empty cell", as a cell with nothing in it is.
- A header cell that is a picture is read before the cells it heads by the picture's
  words, without "image": "Blue shield Low" down the column beside it, and "Blue shield"
  at `rowheader`. On the header cell itself `rowheader` says "row 3 of 4".
- A cell that shows a picture among words is said by its words, the attachment's
  character where the picture stands, and then the picture's words with "image": "Crest
  Worn ￼ daily, Blue crest image". `describe` says "Worn ￼ daily, Blue crest image
  cell 2 items is in the VoiceOver…". `in` goes to the cell's text area, "In Worn ￼
  daily, Blue crest image cell 2 items text Worn  Blue c…", and `in` again into it, "In
  text Worn  Blue crest image  daily", where `right` moves by word, "Worn", "Blue crest
  image", "daily". `out` comes back to the text area, `right` there is the picture's
  image, "Blue crest image", and `out` again is the cell, "Out of Worn ￼ daily, Blue
  crest image cell 2 items". Until 2026-10-13 such a cell was "Crest Worn ￼ daily", and
  one `in` went into its text.
- The attachment's character, U+FFFC, is in a transcript wherever VoiceOver was given it
  to say. Nobody has heard what VoiceOver voices for it. The system's speech synthesizer
  says nothing: `say -o` writes "Sign ￼" to a file as long as "Sign", 0.70 seconds, and
  the character alone to one of 0.01 (macOS 27.0 with the default system voice, on a
  workstation, with no sound played).
- A row that has nothing to say, of cells that hold nothing or decoration alone, is
  passed over: `nextline` and `right` go from the row of words above it to the row of
  words below, and back, so a step list counts no step for it. `ax:lines` prints the row
  and the row of words after it as one line of four characters, `LINE 0.2 RANGE 25,4`,
  whose text is two spaces before the attachment's character, and `ax:links` no run at
  the row. Between two rows of words, a step with no new phrase, "group", "text text
  group" or a bare "table" is a reader that gives such a row to stop on, and a row of
  words that says nothing by line, or that `in` does nothing on, is one that has the row
  in the wrong line or with its break (the entry of 2026-10-13 on rows that have nothing
  to say). Inside a table of data the row is still there: `nextline` down a column says
  "empty cell" at it, for a cell of decoration as for a cell with nothing in it.
- `left` straight after `right` says the item VoiceOver is on again, which leaves no
  line in a transcript, and the second `left` moves back. A step list that turns round
  to come back to a row needs both.
- `ax:links` prints the group the text gives at each such row: `ATTACHMENT AXGroup LABEL
  "Left side, Right side" … CHILDREN AXTextArea,AXTextArea`, the label a client is given
  and the cells' text areas on screen. It prints the first sixty of a text's links and
  attachments, and in continuous scroll one text is the whole book: `"ax:links=WORDS"`
  prints sixty from those words on, as `"ax:links=Words before the squares"` does for the
  book's last section.

`ax:tables`
([accessibility observer](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#accessibility-observer))
prints what the text gives at each row's character before anything is said. For
each table a `TABLE` line has its place in the text, its label, how many rows it holds and
shows, the row it says is selected, its count of rows and columns in the whole table, and
the header it gives for each column and each row by its words, with nothing between the
quotation marks where a row or a column has none. The first table of a column is given
whole: its attributes by name, a `TABLEROW` line for each of its first twelve rows, and for
each cell a `TABLECELL` line with the rows and columns it covers, what it says, what it
holds (`AXTextArea` on screen and nothing off it, `AXLink` for a cell that is a link, or
`AXImage` for each picture of a cell that shows pictures) and
its actions, `AXPress` first for a cell that is pressed. A `TABLEHELD` line follows for
each thing a cell holds that is more than a text area of its words, a link, an image or a
text area that is called something: its role, its label, title, value and help, what it
holds in turn, and its actions. `"ax:tables=WORDS"` prints the
tables from those words on, the first of them whole, which in continuous scroll is the way
to a table that is not the book's first.

Open the reader at a section of tables (`"launch=-SampleHref OPS/grids.xhtml"`,
`OPS/ledger.xhtml`, `OPS/tallrow.xhtml`, `OPS/edges.xhtml`). At 600 points and 17, the first
page of the tables of data holds the first table and the second page the next two and one
row of the fourth; the long table's first page holds its header row and seven entries, the
tall row's first page its header row alone, and the first page of the header cells that are
links their whole table, under two lines of words. The section of squares inside grids (`OPS/squares.xhtml`) has its
table marked as layout on its first page and its table of data at the top of its second,
one `ax:next` on. Its last table is some pages further and opens a page of its own:
`"launch=-SampleHref OPS/squares.xhtml#crests"` opens the reader there, in pages and in
continuous scroll. The section of gaps inside grids (`OPS/gaps.xhtml`) has its table marked
as layout on its first page too, and its table of data at the top of its second, which goes
on to "Line 01 after the tally.". In continuous scroll the reader opened at a section shows that section,
which the `VISIBLE` range of a `STATE` line says, though VoiceOver's opening phrases are the
book's first lines. `ax:caret=WORDS` before `ax:focus in` starts VoiceOver on a line
near a table, which continuous scroll needs: a session that came into the text without it
read from a place of VoiceOver's own, fifty lines off.

After `in` and `line`, the first `nextline` leaves VoiceOver on its line and no phrase in
the transcript (the line said again would not be recorded a second time), and the second
moves: `in line nextline nextline in` goes into the table on the line below. That first
step is not idle: it goes to the end of the line
([key commands](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#key-commands);
[VoiceOver enters a text view at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point)),
and the `AXSelectedTextChanged` line after it has `SELECTION 22,0`. `in` goes into what
stands just before the insertion point. With one
`nextline` the `in` is sent on the line of words, where it does nothing, and the moves after
it go by word through the page, as in four sessions of run 38416874099.

By word from a line `ax:caret` names, the first `right` says the line's first word, so a row
below a line of four words is the fifth `right`: `"ax:caret=Words before the layout" ax:focus
in right right right right right in`. With four the `in` is sent on "layout.", where it does
nothing, and the `out` meant for the row leaves the text, as in four sessions of runs
38425341556 to 38427534348.

### Safari on Mac

A session of Safari records what VoiceOver says of a section of the fixture as a web page:
the book's own XHTML, with nothing of the reader in it. It is what the reader is set beside
where the two are said to agree
([compare with Safari and a stock text view](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#compare-with-safari-and-a-stock-text-view-before-blaming-the-app)).
On a hosted runner a session opens with
`safari=OPS/grids.xhtml` ([Hosted Mac sessions](#hosted-mac-sessions)); the runner script
takes `--safari` with Safari already open at the page. How such a session runs, and what
Safari did on a fresh runner, is in
[Safari as an independent reference](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#safari-as-an-independent-reference).
A session there is read against these, which are Safari's and VoiceOver's own (Safari 27.0.1
on macOS 27.0.1;
[Safari reads tables with web-page speech](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#safari-reads-tables-with-web-page-speech)):

- VoiceOver starts on the page, "Tables of data web content", or on the window's toolbar,
  and then comes to the page by itself. `ax:focus` gives the page the keyboard, and `in`
  goes into it: "In Tables of data web content heading level 1 Tables of data". If VoiceOver
  were to stay on the toolbar, `ax:focus=address ax:focus` brings it to the page by a change
  of keyboard focus, from the address field.
- `right` and `left` are VoiceOver's next and previous item, and they are how a page is
  read: a heading, a paragraph, a table, and then each cell of the table in turn, with "end
  of table" as an item after the last. `nextline` outside a table said nothing in six
  presses, and `line` reads the item.
- `nexttable` moves to the next table of the page from anywhere in it, and says the table
  as arriving at it does.
- `in` on a table goes to its first cell, "In table No selection." and the cell. Inside,
  `right` and `left` go along a row and on into the next, `nextline` and `previousline` down
  and up a column. At the foot of a column `nextline` goes to the top of the next, and at
  the foot of the last it says "end of table". `out` leaves the table, "Out of table"; sent
  after "end of table" it left the page, "Out of Tables of data web content".
- VoiceOver's cursor is on what a cell holds, a text or a link, and not on the cell: its
  hint is "You are currently on a selectable text, inside of a cell." `actions` there is the
  text's or the link's own menu.

For Safari the observer's `ax:tables` prints a `WEB PAGE` line with the page's title, a
`WEB CHILD` line for each of the first sixteen things the page holds, by role and words, and
for each table a `WEB TABLE` line with its title, its counts and the headers it gives for its
columns and its rows, and `WEB TABLEROW` and `WEB TABLECELL` lines for its first six rows, each
cell with the rows and columns it covers, what it holds, the header cells it names for itself
and its actions. The first table's attributes and its first cell's are given by name.

### Hosted Mac sessions

The same reader, probe, observer and runner script record real VoiceOver speech on GitHub's
hosted `xcode-27` runner
([hosted Mac runner](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#purpose-and-limits)).
It is acceptance evidence for the Mac; see [Acceptance and evidence](#acceptance-and-evidence).
The [Mac VoiceOver workflow](../.github/workflows/voiceover-mac.yml) builds the reader at a
ref, runs one or more sessions and uploads their transcripts. The runner is shared, so one run
holds every session a piece of work needs, and it is started through `scripts/hosted-run.py`;
[Sharing the runner](#sharing-the-runner) has the rules. The workflow starts only by hand:

```sh
python3 scripts/hosted-run.py voiceover-mac.yml -f width=600 -f text_size=17 \
  -f steps='ax:next ax:lines ax:focus in line nextline ; ax:next ax:focus in lastword line nextline
            width=1100 text_size=23 ax:next ax:lines ax:focus in line nextline
            flow=scrolled ax:next ax:next ax:focus in line nextline'
gh run watch RUN_ID --exit-status
gh run download RUN_ID --name voiceover-mac-transcripts --dir .build/voiceover/hosted/RUN_ID
```

That is four sessions in one run: two in a window 600 points wide at 17 points, one in a
window 1100 wide at 23, and one in continuous scroll. The script takes the `-f` inputs of
`gh workflow run`, and the branch it starts the run from is built unless the `ref` input names
another one. How a step list splits into sessions, and what a session's own settings and
`ref` do, are in
[session grammar and per-session settings](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#session-grammar-and-per-session-settings).
The inputs, all optional:

- `ref`: a branch, a tag or a full commit SHA whose reader and probe are built, with the
  harness of the `--ref` branch.
- `steps`: the steps `scripts/run-voiceover-mac.py` takes, quoted as on a command line, as in
  `"activate=Next Page"`. Each session's `ax:width` with its width comes before its own steps.
  Left empty, one session checks a page boundary: the left column's entry line and two lines
  down, a Next Page activated through VoiceOver, and the new page's entry line and second
  line. The entry line
  after the turn must be the page's first: with the fault of
  [#337](https://github.com/vocaro/EPUBLib/issues/337) it is the third. The session brings
  VoiceOver to the column by `ax:focus=search ax:focus=0`, without which it can pass on a
  reader that has the fault.
- `width` and `text_size`: the window width and the launch text size in points, 1100 and 23
  unless given, for a session that gives none.
- `flow`: `paginated`, or `scrolled` for [continuous scroll](#continuous-scroll), which needs
  its own steps, for a session that gives none.
- `launch`: further launch arguments of the reader, quoted as on a command line, for a
  session that gives none. `-SampleHref OPS/labels.xhtml` opens the book at a section, with
  no page turns to reach it, and `-VerificationBook paragraphs` opens the other book.
- `links`: how VoiceOver announces a link or an attachment in text: `Speak`, `Change Pitch`,
  `Play Tone` or `Do Nothing`. `Unchanged`, the default, leaves the runner's own setting. See
  [Links](#links). It is set once, before the first session, so it is the one thing sessions
  of a run cannot differ in.
- `pause`: the runner's `--pause`, 5 seconds unless given, for a session that gives none.
- `advance_after`: the runner's `--advance-after`, for a session that gives none. Empty keeps
  the fixed pause.

A session's own settings, before its first step, are `width=600`, `text_size=17`,
`flow=scrolled`, `"launch=-SampleHref OPS/labels.xhtml"`, `pause=3` and `advance_after=0.5`.
`launch=` with nothing after it is no further argument, and `advance_after=` the fixed pause.
A session of settings alone is the page-boundary session with them.

`safari=OPS/grids.xhtml`, among a session's own settings, makes it a session of Safari: that
section of the fixture as Safari shows it, in place of the reader
([Safari on Mac](#safari-on-mac)). The sessions script unpacks the fixture's EPUB on the
runner, opens the section in Safari as
[Safari as an independent reference](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#safari-as-an-independent-reference)
describes, keeps its picture of the screen as `safari-session-N.png` in the download, and gives
the runner script `--safari`. Such a session has a width and a pace. A text size, a flow or
launch arguments of its own are refused, and it must give its steps. The workflow has no input
for it, so it is a session's own word, and sessions of Safari and of the reader share a run.
`runner.txt` names Safari's version.

The job's log, `sessions.txt` and
the run's summary page give each session's settings before its outcome, where the run's name
gives the `width` and `text_size` inputs only:

```text
Session 3: 600 wide at 17 points, scrolled, 4 s pause; completed (exit 0) in 45 s; mac-20261013-042246-037894.transcript.txt; -SampleFlow scrolled -SampleFontSize 17 --pause 4 ax:width=600 ax:next ax:next ax:focus in line nextline
Session 4: 1100 wide at 30 points, paginated, 3 s pause, next key 0.5 s after a phrase; completed (exit 0) in 29 s; mac-20261013-042347-959280.transcript.txt; -SampleFlow paginated -SampleFontSize 30 --pause 3 --advance-after 0.5 ax:width=1100 ax:next ax:lines ax:focus in line nextline
```

A job's time limits, and how many sessions fit in one, are in
[batching sessions](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#batching-sessions),
with the rule for `advance_after`: on 2026-10-13 four sessions of five or six steps, each with
a width, text size, flow or pause of its own, took 239 seconds of a job of 5 minutes 50
seconds, the build 82 of them (run 38344667427). A transcript offered as acceptance evidence is
recorded at a fixed pause; see [Acceptance and evidence](#acceptance-and-evidence).

The job fails unless every session exits 0
([outcomes and downloads](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#outcomes-and-downloads)).
`sessions.txt` in the download gives each
session's settings, outcome, transcript and command: 124 means the deadline was reached, 125
that the runner script stopped the session, 2 that it refused the steps, and 126 that VoiceOver
would not switch back off after it ("VoiceOver not restored"). The download also holds a
`mac-STAMP.transcript.txt` for each session in order, `runner.txt` with the run's
provenance and VoiceOver's [link setting](#links), the observer, `xcodebuild` and build logs, a
screenshot of the runner's screen at the end, and `crash-NAME.ips.txt` for VoiceOver, the
reader or Safari where one quit. The job's log prints each transcript, and the script writes
each session's steps and speech to the run's summary page, under its settings and outcome.
Copy what must be kept
([evidence collection](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#evidence-collection)).
A failed job also uploads `voiceover-mac-result-bundles` and adds `banner-and-dictation.log`
to the transcripts.

A hosted session differs from one on a workstation as
[differences from a workstation](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#differences-from-a-workstation)
describes; in the reader a full column holds one line fewer, 17 at 23 points.

The workflow prepares the runner before it builds, with the commands of
[preparing a disposable runner](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#preparing-a-disposable-runner),
which never run on a workstation. Keep `runs-on: xcode-27`
([billing check](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#billing-check)).
To see what a run cost, expect `"billable": {}` from:

```sh
gh api repos/vocaro/EPUBLib/actions/runs/RUN_ID/timing
```

#### Sharing the runner

Every agent session's VoiceOver runs share the account's five macOS jobs, and the rules for
them, with what `scripts/hosted-run.py` does about each, are in the shared
[sharing the runner](https://github.com/vocaro/apple-engineering/blob/main/guides/hosted-runner.md#sharing-the-runner)
and the sections after it. The queue the script prints spans every enrolled repository; only
this repository's runs on the branch count against the branch's cap. On the evening of
2026-10-12, when the unit tests ran there too, a job waited a median of 13 minutes for a
runner and 75 at worst. Nine ways of giving a table cell that is a link were heard in two
runs, behind one launch argument, where a build for each would have been nine (runs
38425952070 and 38428938679, the entry of 2026-10-13 on such a cell).

```sh
python3 scripts/hosted-run.py
python3 scripts/hosted-run.py voiceover-mac.yml -f steps='width=600 text_size=17 in line ; in line'
```

### Physical iPhone and iPad

Agree a window with the owner and reserve the device before any session on it
([device reservations](https://github.com/vocaro/apple-engineering/blob/main/guides/shared-host.md#device-reservations);
[owner devices and session windows](https://github.com/vocaro/apple-engineering/blob/main/guides/device-testing.md#owner-devices-and-session-windows)).
Choose each device explicitly and run the native probe on it:

```sh
TEST_RUNNER_VOICEOVER_STEPS='visible,touch=Page boundary,read,activate=Next Page,visible,touch=word,read' \
xcodebuild -project Examples/VoiceOverVerification/VoiceOverVerification.xcodeproj \
  -scheme VoiceOverProbeIOS -destination 'platform=iOS,id=YOUR_DEVICE_ID' \
  -derivedDataPath .build/voiceover/ios -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$VOICEOVER_TEAM_ID" \
  -only-testing:VoiceOverProbeIOS/VoiceOverProbe/testCaptureNavigation \
  -resultBundlePath .build/voiceover/iphone-session.xcresult test
```

Use a new result-bundle path for each run, including the iPad. The native service enables
VoiceOver if necessary and restores its original state on normal test completion; the
transcript's `voiceOver` line says which. The run's deadline, the state check afterward and
the owner's XCTest UI Automation passcode, with what to do when it has lapsed, are in
[UI automation authorization](https://github.com/vocaro/apple-engineering/blob/main/guides/device-testing.md#ui-automation-authorization)
and
[devicectl states and timeouts](https://github.com/vocaro/apple-engineering/blob/main/guides/device-testing.md#devicectl-states-and-timeouts).
The device's own log shows a lapsed authorization:

```sh
idevicesyslog -u YOUR_DEVICE_ID -p "testmanagerd|automationmode-writer|AutomationModeUI"
```

On 2026-10-13 an iPad authorized at 20:13 the evening before ran its last session at 04:01,
and from 04:15 refused twelve sessions of two branches, until its owner entered the passcode
at 07:53.

A probe that fails or is stopped part way leaves VoiceOver on, on a device its owner then
picks up. Read the state from the Mac and switch it off there, and keep whatever else
VoiceOver read on the device out of every record
([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)):

```sh
xcrun devicectl device info voiceover --device YOUR_DEVICE_ID
xcrun devicectl device settings voiceover --device YOUR_DEVICE_ID --disable
```

The probe launches the reader and performs the comma-separated steps, recording VoiceOver's
phrase after each, and ends with `finished`: a transcript without that line stopped early.
Without `TEST_RUNNER_VOICEOVER_STEPS` it reads forward from the first item.

- `read`: move forward until VoiceOver stays on the last item, which one move back and a move
  forward confirm. Where that settles nothing, because the item before says the same or
  VoiceOver does not move back, three more repeats end the read, as three did before. A
  `read` line says which way it ended.
- `forward=COUNT`, `backward=COUNT`: that many moves to the next or previous item, where
  `read` would go on through a whole book in continuous scroll. A phrase that repeats the last
  waits three seconds for a new one, so a move that stays on the last item costs those
  seconds.
- `visible`: the window size and each column's first and last numbered lines as XCTest sees
  them, to compare with the speech. Lines listed above or below the window, as continuous
  scroll lists them, are counted apart.
- `touch=LABEL`: touch the first item whose label begins with LABEL. Under VoiceOver a touch
  moves its cursor there; `touch=word` is the first numbered line.
- `activate=LABEL`: touch the item, then double-tap, which is VoiceOver's activation. The
  probe goes on once the screen has changed and held still for half a second, after two
  seconds at most, and a `settled` line says which.
- `point=X:Y`: touch a place in the window, as fractions of its width and height, whatever is
  listed there.
- `doublepoint=X:Y`: double-tap that place, away from the cursor item's activation point,
  without first moving VoiceOver's cursor. The probe waits for the screen as after `activate`.
- `keyactivate`: send VoiceOver's Activate key, Control-Option-Space, without moving its
  cursor or changing the chosen rotor action, then wait for the screen as after `activate`.
  Like `doubletap`, both steps are skipped after `choose` could not find the requested action.
  Use off-target double taps for the activation acceptance matrix; this is a diagnostic input.
- `flick=down`, `flick=up`: one finger steps through the rotor. With the cursor on a line of
  a page it offers the line's actions, Next Page first; `doubletap=LABEL` on that same line
  then performs the chosen one without moving the cursor. A line with no action, as plain
  text is in continuous scroll, leaves the rotor on its own setting, and the flick steps by
  that.
- `choose=NAME`: one finger down through the rotor until VoiceOver names an action that begins
  with NAME, twelve steps at most, each phrase recorded: where an action stands in an item's
  list depends on what else the item offers. When it is not offered the step ends in
  `MISSING`, and the next `doubletap` is skipped and says so, since it would perform
  whichever action the rotor had come round to. The rotor must stand on Actions:
  `rotor=Actions` first settles it, and ends in `MISSING` where the item has no actions.
- `chooseup=NAME`: the same search with upward flicks, for an iPhone in landscape where the
  downward flick does not register. It keeps the same missing-action and activation guards.
- `keyrotor=LABEL`: the same setting search as `rotor=LABEL`, using VoiceOver's
  Control-Option-Command-Right Arrow command instead of a two-finger turn. Use it where
  simulator touch geometry prevents the turn from registering.
- `flick=right`, `flick=left`: VoiceOver's next and previous item; `flick=right*12` repeats it.
- `rotor=LABEL`: two fingers turned on the glass, which turns VoiceOver's rotor, repeated
  until VoiceOver's phrase begins with LABEL, thirty turns at most: `rotor=Headings`.
  `flick=down` and `flick=up` then move by that setting, heading to heading. Without a label
  it turns the rotor once. Turn it after the touch that places the cursor. The turns are of
  several sizes, and a step that does not reach LABEL ends in `MISSING`.
- `rotate=landscape`, `rotate=portrait`: an iPad shows two columns in landscape and one in
  portrait. The probe waits for the screen as after `activate`, three seconds at most. End a
  session in the orientation it started in.
- `listen=SECONDS`: every phrase VoiceOver speaks in that time, each as a `heard` line, where
  another step records the one phrase standing when it ends. Use it after a step that makes
  VoiceOver speak by itself, as a page turn under its cursor does.
- `readall`: VoiceOver reading on by itself from the item under its cursor, as two fingers
  swiped down start it on the glass, by its Read All key, Control-Option-A; `readall=top` is
  Control-Option-B, from the top of the screen. A simulator's VoiceOver takes the key ("Read
  All From Current Item" in its log); on a device the step is not known to do anything.
  Nothing is recorded at the step: put a `listen=` after it, long enough for what is to be
  read, and no touch or move.
- `state`: the sample's own line of what the reader reports as selected and what its
  selection action was last given, "Selected: nothing. Used: nothing.", which
  `TEST_RUNNER_VOICEOVER_LAUNCH='-SampleSelectionLine YES'` puts under the reader. XCTest
  reads it from its snapshot, so no touch moves VoiceOver's cursor.
- `find=LABEL`: whether anything on screen has a name that begins with LABEL, and what kind
  of element at what frame: an edit menu's Copy, which is in no item's list of actions.
- `press=LABEL`: a finger held on the item for a second. With VoiceOver off it selects the
  word under it and brings up the edit menu. The finger is put at the middle of the item,
  so press a cell of a table of data, which is an item of its own and whole on screen. A row
  of a table that is not data is one item as wide as the column: its middle is beside a
  narrow table, and the press selected the row's whole line, "Left side	Right side". And a
  cell cut by the reader's lower edge on an iPhone simulator was pressed at that edge: the
  press selected its row and the row below as the view moved under it, and the same cell
  pressed again, then whole on screen, gave its word.
- `wait=SECONDS`, and `screenshot`, attached to the result bundle: what is on the glass,
  independent of every accessibility snapshot.

`TEST_RUNNER_VOICEOVER_FONT_SIZE` sets the launch text size, `TEST_RUNNER_VOICEOVER_FLOW=scrolled`
opens the book in continuous scroll, `TEST_RUNNER_VOICEOVER_HREF` opens a section other than
the first (`OPS/labels.xhtml`), `TEST_RUNNER_VOICEOVER_BOOK=paragraphs` opens the book of
ordinary paragraphs and `TEST_RUNNER_VOICEOVER_LAUNCH` gives the reader further launch
arguments, with spaces between. `TEST_RUNNER_VOICEOVER_LAUNCH='-SampleStepAfter 30'` has the
reader make one scroll step or page turn by itself, 30 seconds after the book opens: a move
VoiceOver did not make, as a key on a keyboard or a host's own command is. Count the steps
before it into the delay (a touch costs about five and a half seconds) and put a `listen=`
across the moment. `-SampleDarkAfter 18` has the reader turn dark by itself in the same
way, as a host does that follows the time of day: the page is shown again in place, with
the same lines and new items for them, all but the one under VoiceOver's cursor.
`-SampleControls none` shows the reader with none of the host's controls above it, as a
host does that hides them while a book is read: VoiceOver reading on by itself does
differently after a page turn with and without them
([#554](https://github.com/vocaro/EPUBLib/issues/554)).
`-SampleHides YES` puts the sample under `epubReaderHidesControls`, and `-SampleHideAfter 20`
has it hide its controls by itself 20 seconds after the book opens, as VoiceOver's Magic Tap
would with VoiceOver already on: what VoiceOver reads of hidden controls, which a simulator's
VoiceOver cannot be made to hide with Magic Tap.
`-SampleSearch word00` submits that search once the book is ready, as the strip's field does,
so that its match row has 99 results to step through, and `-SampleSearchAfter 6` submits it
that many seconds later: after the text built again for `-SampleFontSize`, which on a Mac
moves the view under a search result in continuous scroll and takes VoiceOver's entry back to
the first line on screen. `touch=Next Match,doubletap=Next Match,listen=6` on a simulator,
and on the Mac eleven `right` from `ax:focus=search` and `activate=Next\ Matc`, step through
them under VoiceOver. The Mac's VoiceOver reads the button's value before its name, and the
runner checks the name in the phrase's first 64 characters, so the name is given cut short
([#49](https://github.com/vocaro/EPUBLib/issues/49)).
`TEST_RUNNER_VOICEOVER_OFF=1`
leaves VoiceOver off, so the same steps are plain touches: use it to tell a VoiceOver failure
from one of the reader's own. The probe stops when the reader is no longer in the foreground.
Another session's tests on the same device bring their own app forward or switch VoiceOver
off; discard such a run.

The probe turns pages by activating the page buttons or a line's Next Page action, for what
XCTest cannot do with VoiceOver
([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)).
[Acceptance and evidence](#acceptance-and-evidence) says which checks need a physical
device and which a simulator settles.

### Simulators

`scripts/run-voiceover-simulator.py` runs the same probe on simulators of its own, with no
device, no Simulator window and no sound, under the shared
[runner contract](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#runner-contract).
Its sessions are acceptance evidence for what VoiceOver reads and in what order, and not for
what VoiceOver activates ([Acceptance and evidence](#acceptance-and-evidence)). On the shared
host its build and runs go through
[heavy-work admission](https://github.com/vocaro/apple-engineering/blob/main/guides/shared-host.md#heavy-work-admission),
as a configured lane (`python3 scripts/eng run LANE`) or with
`python3 scripts/eng admit -- COMMAND`; the plain commands here are for contributors' own
machines:

```sh
python3 scripts/run-voiceover-simulator.py
python3 scripts/run-voiceover-simulator.py --device iPad-Air-13-inch-M4 --font-size 23 \
  --steps 'rotate=landscape,visible,touch=Page boundary,read,rotate=portrait'
```

The runner generates the fixture and project if they are missing or stale and builds the probe
once. It creates an iPhone 17 Pro and an iPad Air 13-inch (M4) on pinned iOS 27.2 build
`24B5110a` (`--device` and `--runtime` choose others) and runs them at the same time, under
`--timeout`. `--steps`, `--font-size`, `--flow scrolled`, `--href OPS/labels.xhtml`,
`--launch '-SampleSelectionLine YES'` and `--voiceover-off` are the probe's settings above.
Each simulator gets `simulator-TYPE-STAMP.transcript.txt` beside its log and result bundle in
`.build/voiceover/results/`.
The default cursor-activation mode has a 600-second timeout and the guards described under
[Investigating cursor activation](#investigating-cursor-activation).
Stock mode defaults to 300 seconds.

The `BUILD` line gives the probe's build revision, recorded as
[evidence collection](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#evidence-collection)
describes in `voiceover-build-revision.txt` in the derived data folder (`--derived-data`
chooses it), which `--skip-build` reads. A build this runner did not record, including one
built elsewhere, has `BUILD unknown`; the separate `CHECKOUT` line gives the checkout's
current revision. `python3 -m unittest discover -s scripts/tests -p test_voiceover_simulator.py`
checks this bookkeeping with temporary Git repositories and fake tools, without building or
starting a simulator; it also runs in the local gate's offline script checks.
The build-revision checks are recorded on
[#504](https://github.com/vocaro/EPUBLib/issues/504#issuecomment-6283694583).

Four things went wrong in the first runs, and the runner and probe now allow for each:

- **Sound**
  ([muted speech capture](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#muted-speech-capture)).
  Nothing runs until each simulator's volume reads 0. The transcript has an `UNMUTED` line
  where a simulator lost its mute and was muted again, and a `VOLUME gave no reading` line
  where a check got no answer in five seconds.
- **A VoiceOver that is on and silent**
  ([readiness and silent start](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#readiness-and-silent-start)).
  The probe waits for VoiceOver's first phrase, three minutes at most, or as long as
  `--start-limit` says; the `voiceOver` line then says `silent for its first 44 s`. On
  2026-10-14, with five sessions' runs on the Mac, five sessions in thirteen were stopped
  silent at three minutes and one at seven, and those that spoke took 75 to 292 seconds;
  `--start-limit 600` with `--timeout 1200` saw five in a row through.
- **An xcodebuild that does not end**
  ([the xcodebuild diagnostics hang](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#the-xcodebuild-diagnostics-hang);
  [diagnostics collection](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#diagnostics-collection)).
  A rotated iPad logs a warning in a probe that passes ("Support for all orientations will
  soon be required"), and xcodebuild then ran on for 22 seconds, 30 seconds, a minute, twice
  more than five minutes, when it was stopped, and once the collector's whole ten. The runner
  passes `-collect-test-diagnostics never`. If xcodebuild has still not ended `--exit-grace`
  seconds after the probe, the runner stops it and its collector, takes the speech from
  xcodebuild's output or from the unfinished result bundle, whichever holds more, and says so
  in a `STOPPED` line.
- **Other sessions**
  ([results and restoration](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#results-and-restoration)).
  One probe failed with "Critical process xctest crashed" while other sessions' unit tests
  were running on the Mac; its own transcript was complete. `FAILURE` lines give XCTest's
  reasons.

A stock simulator session establishes what VoiceOver reads and in what order, not that
VoiceOver can activate anything:
[what stock simulator VoiceOver cannot do](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#what-stock-simulator-voiceover-cannot-do)
has why. In landscape a double tap on the iPad's Next Page at (43, 134) arrived at (890, 43),
where nothing is, and on the iPhone it landed in the search field and brought up the
keyboard; an item from before a move, met after `activate=`, is the case of
[#428](https://github.com/vocaro/EPUBLib/issues/428) under "Harness pitfalls and current
results". On physical devices VoiceOver performs every one of these
([iPad and iPhone verification](https://github.com/vocaro/EPUBLib/issues/28#issuecomment-6159294047)).
End a session that rotates with `rotate=portrait`: a transcript with `settled: nothing on
screen changed in 2.0 s` after its `doubletap=Next Page` began on its side.

Whether the rotor kept its place across a page turn can be read on a simulator all the same
([reading the rotor without activation](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#reading-the-rotor-without-activation)).
Choose Next Page with `flick=down`, turn the page under the cursor with `doubletap=Next Page`,
which arrives as a plain touch on the control strip's button and leaves the cursor where it
is, `listen=4` for what VoiceOver says by itself, and `flick=down` again. "Previous Page" says
the rotor kept its place; "Next Page" again says it started anew. Across a page that is shown
again in place it is read the same way, with the sample making the reader dark in place of the
double tap: `flick=down,listen=22,screenshot,flick=down` under `-SampleDarkAfter 20`.

VoiceOver keeps a log of its own in a simulator, which says what VoiceOver did where a
transcript says only what it read
([VoiceOver's vot log](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#voiceovers-vot-log)).
The runner streams it for each of its simulators with `--vot-log`, into
`simulator-TYPE-STAMP.vot.log` beside the transcript, from the moment the simulator is muted
until the probe has ended. What it showed of VoiceOver's own cache is in
[VoiceOver moves through a cache of the items around its cursor](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-moves-through-a-cache-of-the-items-around-its-cursor)
and
[a layout change makes VoiceOver drop its cache about 0.8 s later](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#a-layout-change-makes-voiceover-drop-its-cache-about-08-s-later).
The stop after the scroll bar is adjusted was found this way
([#342](https://github.com/vocaro/EPUBLib/issues/342), under "Harness pitfalls and current
results"). The log of a physical device holds whatever else its owner's device did, and is
not read.

The voice VoiceOver speaks with is in the simulator's speech extension's log, read as the same
section describes; the voices the reader's languages are given were read this way
([#65](https://github.com/vocaro/EPUBLib/issues/65#issuecomment-6164353724)).

Timings and the simulators' geometry are in
[timings and simulator geometry](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#timings-and-simulator-geometry).
In landscape the sample's control strip stacks and leaves its reader one line at 17 points, so
`visible` finds no numbered line on the first spread. The stock observations above are of the
iOS 27.0 runtime; the runner now defaults to iOS 27.2 with guarded cursor activation
([Investigating cursor activation](#investigating-cursor-activation)).

#### Investigating cursor activation

The later investigation on [#495](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6283827087) traces the
activation through VoiceOver's own simulator code and records the runtime comparisons and
the diagnostic patch, which the shared
[guarded cursor activation](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#guarded-cursor-activation)
describes with its guards. The guarded bypass is the runner's default on pinned iOS 27.2,
together with the layout-ordering repair below; physical acceptance requirements remain as
described below.

Compare the stock simulator with an off-target double tap and with the keyboard command, and
read the `state` lines
([investigating cursor activation](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#investigating-cursor-activation)):

```sh
python3 scripts/run-voiceover-simulator.py --activation stock --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-2 \
  --device iPad-Air-13-inch-M4 --href OPS/grids.xhtml --launch '-SampleSelectionLine YES' \
  --vot-log --timeout 600 \
  --steps 'touch=Alder,rotor=Actions,choose=Select Cell Text,keyactivate,state,doublepoint=0.5:0.6,state'
```

The issue keeps the patch, its base revision, the full step lists, results and remaining gaps.

The runner defaults to iOS 27.2 and guarded cursor dispatch for that runtime. An explicit
`--runtime` or `EPUB_SIM_RUNTIME` selecting another runtime defaults to stock activation;
`--activation stock` always selects an unmodified control. The guards, the VoiceOver log
marker and the startup canary are those of guarded cursor activation, above. Select the Xcode
with `DEVELOPER_DIR` for both build and run:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta-27.2-beta-3.app/Contents/Developer \
python3 scripts/run-voiceover-simulator.py --activation cursor \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-2 --device iPad-Air-13-inch-M4 \
  --href OPS/grids.xhtml#activation-cell --launch '-SampleSelectionLine YES -SampleControls none' \
  --strict --timeout 600 \
  --steps 'touch=Alder,keyrotor=Actions,chooseup=Select Cell Text,doublepoint=0.5:0.2,expectstate=Selected: Alder. Used: nothing.'
```

This lane currently permits only arm64 iOS 27.2 build `24B5110a`; an unknown build or binary
is refused. `--activation stock --activation-check` runs the canary as a negative control.
The original experiment wrapper delegates to these same checks.

`--strict` makes a missing target, rotor setting or action fail immediately. Assertions also
fail the test: `expect=PREFIX` waits up to five seconds for speech beginning with that text;
`expectcontains=TEXT` waits for speech containing it; `expectstate=TEXT` compares the sample's entire selection line; `exists=PREFIX` and
`absent=PREFIX` check snapshot labels. `focusvisible` checks that speech names a visible
snapshot item; use it for reader text. `mark=NAME` remembers visible
labels, and `changed=NAME` or `same=NAME` compares them. `entertext` moves from a host control
into the text and checks that the first numbered line reached is the first on screen.
`menuback`, after returning to
Chapter two’s heading, checks the native continuation after a chapter menu: Bookmark and
the three controls before it, or consecutive visible words back from chapter one’s last
word. The transcript records which continuation VoiceOver took. `relaunch=FLOW:SIZE:HREF:CONTROLS`
starts another reader workflow while keeping VoiceOver running (`none` hides the host
controls, `normal` shows them). `fresh=FLOW:SIZE:HREF:CONTROLS` starts the next workflow in a
fresh VoiceOver session, which the matrix uses between independent workflows.
`--book paragraphs` selects the ordinary-paragraph fixture.

Repeat the assertion matrix with:

```sh
python3 scripts/qualify-simulator-voiceover.py
python3 scripts/test-simulator-voiceover-activation.py
```

The matrix creates fresh iPhone 17 Pro, iPhone 17 Pro Max and iPad Air 13-inch M4 simulators
at 17 and 23 points and runs at most two concurrently. It exercises both orientations and
both reading flows, checking page turns, links, image inspection,
selection, updated rotor actions and reading after activation, plus both #428 cache cases. It stops on the first failed
session. Both families activate through off-target double taps, matching the device reference.
Its iPhone steps use the keyboard rotor; its iPad steps use rotor gestures. The startup
canary separately checks keyboard activation. Repeated synthetic rotor keys on an iPad
can be interrupted by UIKit's “Keyboard visible” announcements. `--device-steps TYPE=STEPS`
on the ordinary runner records and sends an explicit step override for one requested device;
the qualification runner uses that for the two input paths. The small Python suite checks that unknown builds, altered binaries and missing
hook/canary evidence cannot pass, including older v1/v2 markers that do not confirm the
speaking-layout repair. [Qualification results](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6301363775)
and [device comparisons](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6296467408)
are recorded on #495 with the revisions tested.

The v1 default retained a simulator announcement mismatch, a link's source kept as
VoiceOver's latest speech where the paired native iPhone announced the heading at once, which
the v3 hook's ordering repair, described with the guards above, removes. The
[original failed qualification](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6296767191)
remains recorded; default adoption did not waive that failure. The
[ordering investigation](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6297469108),
the [Pro Max follow-up](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6298557598)
to the first repair, the [v3 hook](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6298857262)
and the [expanded qualification results](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6301363775)
are on #495. Qualification checks a link as the initial reader workflow before the existing
page/image/selection/link checks, with the immediate `expect=Link target reached` assertion
and the forward and backward checks unchanged.

To separate a navigation announcement from activation, the sample's existing
`-SampleStepAfter SECONDS` timer accepts `-SampleStepHref HREF`: it navigates to that
href instead of turning one page. For example, launch at `OPS/body.xhtml#activation-link`
with `-SampleStepAfter 120 -SampleStepHref OPS/body.xhtml#link-target`, focus
`Verification link`, then `listen=125`. This does not activate an accessibility item.
The verification host also accepts positive `-VerificationWidth POINTS` and
`-VerificationHeight POINTS` together to constrain the reader's content size for a
layout comparison. A constrained iPad remains an iPad; it does not establish native
iPhone behaviour
([timings and simulator geometry](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#timings-and-simulator-geometry)).
Neither diagnostic changes the host's layout or navigation without
those arguments.

On an iPhone in landscape, begin on the visible heading with `touch=Page boundary`, not
`touch=word`: its first page contains the introduction and link, and numbered words start
on the next page. Use `keyrotor=Actions` when two-finger turns do not register, then
`chooseup=Next Page,keyactivate` to turn forward. On the numbered page,
`touch=word,keyrotor=Actions,chooseup=Previous Page,doublepoint=0.5:0.2` tests the return
through an off-target double tap. After that, `touch=Verification link,keyactivate` checks
default activation. The [iPhone landscape follow-up](https://github.com/vocaro/EPUBLib/issues/495#issuecomment-6283996460)
records this sequence and its evidence.

### Acceptance and evidence

For each device, exercise supported one- and two-column layouts, normal and larger text,
and a text-size change while the reader is open. Record what
[recording speech evidence](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#recording-speech-evidence)
lists, with the visible first and last numbered words. For the Mac, a speech session run on
the hosted `xcode-27` runner is acceptance evidence, as one on a workstation is; `runner.txt`
in the run's download has its image and image version, and everything else here applies to
it unchanged.

For the iPhone and iPad, a session in the [simulator lane](#simulators) is acceptance
evidence for what VoiceOver reads under the shared
[acceptance rule](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#acceptance-rule),
which also says what still needs a physical iPhone or iPad. For this reader that is:

- activating the item under its cursor: a button, a link, a line's default action;
- performing an action chosen in the rotor: Next Page from a line, Inspect Image, Select Cell
  Text, Follow Link;
- turning the page in landscape;
- on an iPad, what VoiceOver reads after an activation of its own
  ([#428](https://github.com/vocaro/EPUBLib/issues/428), under "Harness pitfalls and current
  results"); `-SampleStepAfter` makes the same move without an activation.

In the steps below that is each double tap whose result is VoiceOver's own doing. A page
turned in portrait with `activate=Next Page` is turned by a plain touch on the button, so the
page that follows and VoiceOver's reading of it count, and that VoiceOver activated the
button does not. No issue is filed to ask for a device session that would only hear a
reading again. In continuous scroll the reader now tells VoiceOver of every move of its
own, and in paging of every page it shows while the cursor is outside the text, and a
simulator and an iPad agree after one.

Sessions that show a change by what VoiceOver said before and after it are recorded on the
same main, as
[comparing runs across builds and environments](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#comparing-runs-across-builds-and-environments)
describes; the probe built in a second worktree in under two minutes. Record a Mac transcript
offered as evidence at a fixed pause, the runner's default, on a workstation or hosted;
`--advance-after` is for exploring.

1. Capture the first spoken line upon entering each column, before advancing. The first
   numbered word must match that column's first visible word.
2. Read successive lines in logical column order. Reach the last visible word, then attempt
   another line; hidden continuation must not become reachable.
3. Activate Next through VoiceOver and verify that the next visible/spoken word is exactly
   the successor of the prior page's last word, without duplication. Check Previous as well.
   On an iPhone and iPad also turn the page from a line: with the cursor on a line of the
   page, choose Next Page in the rotor (`flick=down`) and perform it (`doubletap=LABEL`).
   VoiceOver then reads the first line of the page shown by itself (`listen=4`), a
   screenshot shows its cursor on that line, and each move forward reads the next line of
   that page. Do it from the first page and from a line in the middle of a later page,
   whose lines hold the same characters as the next page's, and with Previous Page.
   Then double-tap again with no flick before it: the page turns again and VoiceOver reads
   the first line of that page, since its cursor is on the item it was on and the action
   chosen still stands. So it is from a data table's cell onto a page that opens with a
   line (`OPS/grids.xhtml`, from "Twelve metres"), and from a line onto a page that opens
   with a cell (`OPS/ledger.xhtml`, from its heading), which VoiceOver reads with its row,
   its column and "Table start" as it reads any cell it comes to: the second double tap
   there turns the page from that cell. From a cell onto a page that opens with a cell,
   as inside a table longer than a page (the same section at 28 points, from "Entry 03"),
   the cursor goes to a new item, read with its row and column, and there the second
   double tap turns nothing. Each of these double taps is a physical device's to show. On
   a simulator the flick after a turn says where the rotor is and no more
   ([Simulators](#simulators)).
   On an iPhone and iPad also have the page turned by something VoiceOver did not do, with
   its cursor on a control and a line of the page held that it has been on
   (`-SampleStepAfter`, under "Physical iPhone and iPad"). In the book of ordinary
   paragraphs, `touch=Bookmark,forward=2,backward=2,listen=25,screenshot,forward=4,visible`
   with the turn at 25 seconds: VoiceOver goes into the page and back to Bookmark, the
   last control before the text, holding the page's first two lines. `listen` records
   nothing but the button, the screenshot shows the next page with the cursor on the
   button, and the moves read that page from its first line, the one `visible` names.
   "Chapter one Heading" at the first move and "Bookmark" at the second is the failure: a
   line of the page before, and the cursor put back on the control. Then with the whole
   page held,
   `activate=Contents,doubletap=VoiceOver Paragraph,wait=1,forward=5,forward=3,touch=Next Page,listen=35,screenshot,forward=9,forward=4,visible`
   and the turn at 50 seconds: the double tap on the book's title under the reader closes
   the menu with nothing chosen, the first move after it has VoiceOver ask for fifty
   items, which is every line of the page, and the touch puts its cursor on Next Page with
   those still held. The ninth move from the button gives the first line of the page
   shown. A chapter chosen from the menu (`activate=Chapter one` in place of the double
   tap) is not that session on a simulator: the reader tells VoiceOver of the page shown
   for the chapter, and it then holds two items each side and does not ask for fifty.
   Neither is the same touch with no moves before it: a line VoiceOver holds and has not
   been on is one it gives up by itself.
   And have the page shown again under a cursor that is on a line (`-SampleDarkAfter`):
   `touch=Bookmark,forward=4,listen=22,screenshot,backward=1,forward=3` with the change at
   18 seconds. `listen` records nothing but the line, the screenshot shows the page dark
   with the cursor on its third line, and the moves read the line above, that third line
   again and the two after it. "Bookmark" at the second of those moves is the failure:
   VoiceOver took an item of the page as it was, and was put on the control it had last
   touched. Then with an action chosen in the rotor on a line,
   `touch=p001w01,flick=down,listen=22,screenshot,flick=down,forward=2` with the change at
   20 seconds: "Next Page" at the first flick, nothing during the `listen`, "Previous Page"
   at the second, which says the rotor kept its place, and the page's second and third
   lines. "Next Page" again at the second flick is the failure: VoiceOver was given a new
   item for the line it was on. On an iPad the same from a data table's cell
   (`OPS/grids.xhtml`,
   `touch=Twelve metres,flick=down,listen=22,screenshot,flick=down,backward=1,forward=3`):
   "Previous Page" at the second flick, then "Opened 1901 Column 2" and "Depth Twelve
   metres Column 3". That cell read without "Column 3" is a failure too: its table has a
   new item and the cell an old one.
   On an iPhone and iPad also have VoiceOver read on by itself across pages, with
   `readall` and a `listen=` long enough for a page or two, at 40 points (`--font-size 40`),
   where a page holds a few lines: `touch=word,readall,listen=170,visible` on an iPhone,
   and on an iPad `rotate=landscape,visible,touch=word,readall,listen=200,visible,rotate=portrait`.
   It reads each line of the page to its last, and VoiceOver's log (`--vot-log`) then has
   "Element Scrolled by Page" with "Page 2" and no speech of it; the next page is read from
   its first line, and in a spread the left-hand page runs on into the right-hand one with
   no turn between them. A line read twice or left out, or a turn after the left-hand
   page, is the failure. What VoiceOver reads between the turn and the new page's first
   line is the host's and VoiceOver's
   ([#554](https://github.com/vocaro/EPUBLib/issues/554)): in the sample it reads the
   control strip, and with `--launch '-SampleControls none'` it stops after the turn. With
   no controls and pages of a line or two (`--font-size 60`, on an iPhone
   `rotate=landscape,visible,readall=top,listen=100,visible,rotate=portrait`) it reads the
   heading's three pages of one line each, "Page bound", "ary verifica" and "tion", and
   stops at the first page of two. A page's last line read without its first is the
   failure: VoiceOver read nothing else of each page when every last line turned the page
   ([#468](https://github.com/vocaro/EPUBLib/issues/468)). And on the book's last page,
   the last of `OPS/veiled.xhtml` (`--href OPS/gaps.xhtml --font-size 12`, `activate=Next
   Page` until VoiceOver says the button is dimmed, at the twelfth, then
   `readall,listen=80`), it reads "Line 60 after the hidden words.", the book's title
   under the reader, and stops; the log has no page scrolled.
4. Confirm heading order, the link's label/action and the image's spoken label.
5. Resize or change typography, wait for the new layout, and repeat the boundary and ordering
   checks. On Mac verify corresponding value-change notifications and fresh text values.
6. On the hidden-labels section, in pages and in continuous scroll: VoiceOver reads "Parked
   title heading" and "By the parked author." and then "Shown opening words.", with nothing
   for the image between them, which has an empty `alt`; "Clipped words in the line."
   between the two shown sentences, and "Parked link to the target" as a link before "Shown
   last words."; it never reads "Words nobody is given." or "Words kept from assistive
   technology."; and a screenshot shows the image and none of the hidden words. On the section with a
   hidden heading over a table, opened in continuous scroll, VoiceOver moving into the text
   meets "Parked table heading" before the table's first row, and the view does not move.
   In pages and in continuous scroll alike, each row of that section's tables is one item
   where it stands, read as its cells' words and not as an image: "First cell Second cell"
   and "Third cell Fourth cell" after the heading, "Fifth cell Sixth cell" and "Seventh cell
   Eighth cell link" between "Line 02 after the table." and "Line 03 after the table.". No
   cell is an item by itself, and moving back gives the same items in reverse. On the last
   row the rotor offers Select Table Text for its two cells and Follow Table Link: Eighth
   cell link, which opens the first section at "Link target reached"; a line beside the
   tables offers none of them. Nothing marks those tables as data and they are not ruled.
   On the section of tables of data, in pages and in continuous scroll, each cell is an
   item. VoiceOver says the header cells that have changed since the cell before, then the
   cell's words, the row at a row's first cell and the column at every cell, with "Table
   start" and the count of rows and columns at the table's first cell and "Table end" at
   its last: "Station, Column header, Row 1, Column 1, Table start, 4 rows 3 columns",
   "Opened, 1901, Column 2", "Station, Birch, Row header, Row 3, Column 1", for the empty
   cell "Depth, Column 3", and "Depth, Forty metres, Column 3, Table end". A cell that
   spans says so, "Service, Column header, Spans 2 rows", and "Hours" is not read under
   "Leaves", which stands below it. "Reopened 1978" is a link: a double tap opens the first
   section at "Link target reached", and the rotor offers Select Cell Text and Follow Link:
   Reopened 1978 after the page's own two. With the rotor on Rows (`rotor=Rows`),
   `flick=down` and `flick=up` move down and up a column: from "Alder" to "Birch, Row
   header, Row 3". The table with `role="presentation"` is read row by row, "Left side
   Right side", though it is ruled like the others, and the ruled table of plain cells cell
   by cell, "North, Row 1, Column 1, Table start, 2 rows 2 columns". On the section with a
   table longer than a page, in continuous scroll, VoiceOver reads on through all forty
   rows and back, every cell once and in order, the view following, and names a column's
   header cell far below the header row: "Sum, Sum 39, Row 40, Column 3" on the way back.
   With the rotor on Rows it moves down a column past the screen, a row at a time. In
   pages the page after the first goes on at the next row's number and names a column's
   header cell though its row is on the page before: "Entry 28, Row 29, Column 1, Table
   start, 41 rows 3 columns" and "Item, Item 28, Column 2" on an iPad at 17 points.
   VoiceOver says "Table start" at the first cell a page lists and "Table end" at the last,
   so a page in the middle of a table says both. On the section with a row taller than a
   page, each page's cell reads the words that page shows.
   On a Mac the same sections are read at each row and inside its table
   ([Tables on Mac](#tables-on-mac)), in a window 600 points wide at 17 points. By line
   and by word VoiceOver says each row of a table of data by its words and "table":
   "Station, Opened, Depth table", "Alder, 1901, Twelve metres table"; and each row of the
   table with `role="presentation"` by its words and "group": "Left side, Right side
   group", "Lower left, Lower right group", each once. `in` on the second says "In Lower
   left, Lower right group 2 items text Lower left", `right` "text Lower right", and `out`
   "Out of Lower left, Lower right group". A reader that calls such a row "Table row" says
   "Table row group" at both rows and none of their words. `in` on "Birch, 1934 table"
   says "In Birch, 1934 table Station Birch", `right` "Opened 1934" and "Depth empty cell",
   `nextline` "Cedar Forty metres", `columnheader` "Depth" and `rowheader` "Cedar". `in` on
   a cell goes into its words, "In text 1934". The cell that is a link is said with
   "hyperlink", "Opened Reopened 1978 hyperlink" along its row and "Cedar Reopened 1978
   hyperlink" down its column. `actions` there holds Select Cell Text, Follow Link:
   Reopened 1978 and "press", and choosing the second, or `activate` on the cell, opens
   the first section at "Link target reached". In the second table VoiceOver says "Hours,
   Leaves Nine" and "Service Express", and moving down from "Stopper" it stays, "Stopper
   column 1, row 4". On the long table's second page `in` on the first row says "In Entry
   08, Item 08, Sum 08 table Entry Entry 08": the header is named from the page before, and
   `rowheader` says "row 9 of 41". In continuous scroll, `in` on "Entry 38, Item 38, Sum 38
   table" says "Entry Entry 38", and twenty-eight `nextline` steps from the header row read
   "Entry 01" to "Entry 28", each once, the view following.
   No session has "ERROR 3" in it.
   On the section of squares inside grids (`"launch=-SampleHref OPS/squares.xhtml"`), in
   pages and in continuous scroll, the row of two pictures nobody describes is "text
   image text image group" by line, by word and with `readall`, between "Top near, Top
   far group" and "Foot near, Foot far group". `in` there says "In group 2 items text
   image" and `out` "Out of group". A reader that gives such a row a name of its own
   says the name, "Table row group" while it was called that, and one that gives it help
   and no name says the help in the name's place. With VoiceOver's cursor on the group,
   after `in` and `out`, `actions` has Inspect Image for its first two items, and
   `"listchoose=Inspect Image"` opens the inspector: `ax:actions=all` then lists Zoom
   Out, Zoom In, Fit and Close. On the section's second page (`ax:next`) the table of
   data says "Sign, Sense table", "Blue badge, Open table" and "Shut table", and `in` on
   the second or the third goes into the table at that row, "In Blue badge, Open table
   Sign" or "In Shut table Sign" and the cell. A row there that says "group" is one
   given as a row's group in its table's place. The cell that holds the picture is "Sign
   Blue badge image" in the second row and "Sign image cell" in the third, and `actions`
   there has Inspect Image for the picture. A reader whose cell holds a text area for the
   picture says the attachment's character there, "Sign ￼" in a transcript for both
   rows, and one whose image has help says the help after "image" each time. On the
   section's last page (`"launch=-SampleHref OPS/squares.xhtml#crests"`), `in` on "Worn
   Blue crest daily, High table" says "Crest Worn ￼ daily, Blue cr…" and `describe`
   "Worn ￼ daily, Blue crest image cell 2 items…", the picture among the cell's words
   said after them; `right nextline` says "Rank High" and "Blue shield Low", the header
   cell that is a picture read by its words, and `left nextline right` "Crest Blue shield
   image", "empty cell" for the cell of decoration alone, and "Rank Blue ring image, Blue
   star image". No session has "ERROR" in it
   (the entry of 2026-10-13 on a table cell that shows a picture).
   On the section of gaps inside grids (`"launch=-SampleHref OPS/gaps.xhtml"`), in pages
   and in continuous scroll, VoiceOver says the rows of words and nothing between them:
   by line, by word and with `readall`, forward and back, "Upper near, Upper far group",
   "Middle near, Middle far group", "Lower near, Lower far group" and "Last near, Last far
   group", and on the second page (`ax:next`) "Tree, Tally table", "Oak, Nine table",
   "Elm, Four table", "Ash, Six table" and "Yew, Two table". Between two of them a step
   with no new phrase, a phrase with nothing in it, "group", "text text group" or a bare
   "table" is a row with nothing to say that the reader has given VoiceOver to stop on.
   `in` on "Middle near, Middle far group", reached by `nextline` or by `right`, says "In
   Middle near, Middle far group 2 items text Middle near", and on "Elm, Four table" "In
   Elm, Four table Tree Elm", where `right` says "Tally Four" and `nextline` "empty cell",
   the cell of the row passed over below it. A reader on which `in` does nothing there has put the
   row passed over in that row's line behind it, and one that says nothing at "Middle
   near, Middle far" by line has left the break after the row passed over in the line
   (the entry of 2026-10-13 on rows that have nothing to say).
   On a Mac a cell is a text of its own, and VoiceOver reads its
   line wherever its cursor is in it. In a window 600 points wide at 17 points, with the
   reader opened at that section (`"launch=-SampleHref OPS/table.xhtml"`), in pages and in
   continuous scroll, `"ax:caret=Shown words after"`, a focus change to the text, `in` and
   `left` put VoiceOver on the first table's second row, "Third cell, Fourth cell group";
   `in` there says "In Third cell, Fourth cell group 2 items text Third cell", and `in`
   again "In text Third cell". `line`
   then says "Third cell" on entering, after `right` has said "Third", after a second
   `right` has said "cell", the cell's last word, and after a third has said "end of text".
   A reader whose cells have no line for the end of their text says nothing for the last
   two, and counts "-9,223,372,036,854,775,808 lines" there for `linecount`, where the
   answer is "1 line 1 visible line". At 56 points the cells take two lines each and the
   table has the page to itself: two `right` steps from the text's first line reach the
   first row, `line` says "First" on entering its first cell and "cell" with the cursor at
   the end of the cell's text, and `previousline` from there says "First".
7. On the section of pictures, in pages and in continuous scroll. VoiceOver stops between
   "Undescribed picture" and "stands here." and says that an image is there, with no name.
   It reads "Decoration" and "passed over." with nothing between them, and the same for
   "Titled decoration". After "Bare jump:" it stops on a link that is an image without a
   name, and activating it goes to "Link target reached". It reads "Jump with decoration"
   and "Described jump" as links, the second also as an image, and "Square with a title of
   its own" as an image between "Titled picture" and "stands here.". It never says "Book
   image", and says "Square with a title of its own" once. It says no word that begins with
   "Unspoken", on iPhone, iPad and Mac. It reads "Ornament", "Plain ornament", "Kept square"
   and "Drawn square" and "passed over." with nothing between them, and after "Quiet jump:"
   stops on a link that is an image without a name, as after "Bare jump:". It reads "Jump
   with an ornament" as a link and nothing more, and "Square shown to all" and "Square with
   a note" as images between their lines' words. On a Mac Find Next Link names the first of
   those links "image" and the second "Jump with an ornament". The first sessions are on
   [#408](https://github.com/vocaro/EPUBLib/issues/408#issuecomment-6164176609) (Mac) and
   [#408](https://github.com/vocaro/EPUBLib/issues/408#issuecomment-6165265644) (iPhone and
   iPad), with their steps.
8. On the section of scenes, on an iPhone and iPad, in pages and in continuous scroll.
   VoiceOver stops between "First scene ends." and "Second scene starts." and says
   "Separator", and never "Image". From "Second scene starts." it goes to "Words after an
   ornament.", "Words after a plain ornament." and "Words after a kept ornament." with no
   stop between them: the book keeps those three rules from assistive technology
   ([#408](https://github.com/vocaro/EPUBLib/issues/408)). On the page
   that holds a rule alone it says "Separator" and nothing else in the text, and Next Page
   from there shows "Last words of the scenes.". On a Mac, in a window 600 points wide at
   17 points, open the reader at the section (`"launch=-SampleHref OPS/scenes.xhtml"`).
   Moving by line VoiceOver says "Separator" between "First scene ends." and "Second scene
   starts." and nowhere else on the page, and reads "Words after an ornament." and "Words
   after a plain ornament." with the spaces that stand for the rule before each; the rule
   that ends the page, before "Words after a kept ornament." on the next, is a line of
   spaces where it stops once and says nothing. Moving by word a rule it is told of is one
   stop that says "Separator"; and `readall` from the page's first word says it once. On the page that holds a rule alone, one `ax:next` step on, it says "In text
   Separator" on entering and "end of text" on the next line. In continuous scroll it says
   "Separator" on the line between "First scene ends." and "Second scene starts." and on
   the line of the rule alone, before "Last words of the scenes.", and on no other. No
   transcript has "splitter", "collapsed" or "image" at a rule.
9. Headings. On an iPhone or iPad VoiceOver says "Heading" after a heading's words, shown or
   hidden, and reads a heading that takes several lines as one item. With the rotor on
   Headings (`rotor=Headings`, turned after the touch that places the cursor), `flick=down`
   moves to the next heading on the page or screen and then to the next one in the book,
   turning the page or scrolling to it, and `flick=up` goes back the same way; `visible`
   after a move shows the page or screen the reader went to. Past the book's last or first
   heading VoiceOver says "Heading not found". Wait a few seconds after the book opens
   (`wait=8`): a chapter not built yet ends the search. On a Mac `nextheading` moves
   VoiceOver to the book's next heading, to "Heading not found" past the last, and the view
   shows the heading. In continuous scroll, and in pages where the heading is on the page,
   VoiceOver reads the heading's words. In pages where it is on another page the reader
   turns to it and VoiceOver reads that page from its top: `line` then reads the heading,
   and `ax:lines` shows the page with the insertion point on the heading's line. `rotor`
   opens on the Heading menu, which lists the whole book's headings in both flows, each by
   its words and level, and `listchoose` moves to the one named, turning the page for it.
   From a page in the middle of the book, with VoiceOver's cursor resting on the column
   (`ax:focus=0` without `in`), `nextheading` goes to the first heading after the top of
   that page, not to the book's first. From a link (`nextlink` first) `nextheading` says a
   heading's level and then its words, "heading level 2 Link target reached", for the
   book's next heading after the link in both flows: in pages the reader turns to its page,
   in a window 600 points wide at 17 points from the first page's link to the page of
   `word1187`. `describe` says the heading is in the VoiceOver cursor, `line` reads it,
   `right` says its first word, "Link", and `nextheading` goes on through the book, from the
   heading's element to the next heading's and from the text by the rotor. `ax:links` on
   the first page lists three children, the last of them the heading "Link target reached",
   and marks each heading `FOCUSABLE`. Where the heading is on the page or on screen
   already, VoiceOver says its level and words and nothing over them: opened at the last
   section (`"launch=-SampleHref OPS/parts.xhtml"`), `nextlink nextheading` says "upper jump
   hyperlink" and "heading level 3 Second part opens", in pages and in continuous scroll.
   "finish.", the word before that heading, in place of it or straight after it is the
   failure. `describe` says the heading is in the VoiceOver cursor, and `line` reads the
   line VoiceOver last read, "Parts below a jump", since nothing was turned or scrolled.
   From the book's last heading `nextheading` says
   "Last heading" and the heading again. `rotor` from a link has the same
   Heading menu. VoiceOver opens its rotor on the menu it showed last, so a session that
   has gone to another menu with `listright` starts the next one there. With `tracking`
   sent first, which turns cursor tracking off, the same steps in pages say the heading
   and leave the page where it is.
10. Links on a Mac, in pages and in continuous scroll, with VoiceOver's link setting at Speak
    ([Links](#links)). `ax:links` lists each link on screen once as a `CHILD`, by its words:
    "Verification link" on the first page, "Parked link to the target" on the hidden-labels
    section, and "image", "Jump with decoration" and "Described jump, image" on the section
    of pictures. None is called U+FFFC. `nextlink` moves to each in turn, VoiceOver says its
    name and "hyperlink", and `activate` from there shows the page with "Link target
    reached". Moving by word and by line VoiceOver says "hyperlink Parked link to the
    target", "hyperlink image" after "Bare jump:", "hyperlink" before "Jump with decoration",
    and "hyperlink Described jump, image". It reads "Verification link." as its words and
    nothing else, and `activate` with the cursor on either word follows that link too. In
    continuous scroll from the top of the book, `ax:links` has "Parked link to the target"
    as its last link `CHILD`, though the link is eleven thousand characters down, and two
    `nextlink` steps say "Verification link hyperlink" and then "words." and "hyperlink
    Parked link to the target", with `SELECTION` at the link and the link's line the first
    on screen; `right` says the link again and then "Shown", `line` "hyperlink Parked link
    to the target Shown last words.", and `activate` straight after the second `nextlink`
    follows the link. Twenty-four `nextlink` steps from the top name the book's twenty-one
    links in order, the cells' among them, and then the last three again, "upper jump",
    "lower jump" and "last jump": those share one screen, and past the book's last link
    VoiceOver begins again with the first one on screen. A
    reader without the link below among the children says "Verification link hyperlink"
    and then "Last link Verification link hyperlink".
11. Actions, on an iPhone and iPad. A line is offered what is in it and nothing else. On a
    page, with the cursor on a line of plain text, `flick=down` reads "Next Page", "Previous
    Page" and "Activate", and then "Next Page" again: each once, and no picture or link that
    stands elsewhere on the page. On the picture's own line it reads "Inspect Image: Blue
    verification square" after the two. In continuous scroll VoiceOver says no "Actions
    available" after a line of plain text or a link, and `flick=down` there reads no action;
    the picture's line says it and offers the inspection alone. A reader that offered more
    said, on any line of continuous scroll, "Previous Page", "Next Page", and the book's
    links by their words.
12. What each kind of item offers, on an iPhone and iPad, on the section "What each line
    offers", which shows them all at once. With the cursor on an item, step through the rotor
    (`flick=down`) until VoiceOver says "Activate Default": what came before it is everything
    the item offers. In pages "Plain words above.", the link "Lone jump" and "Plain words
    below." offer Next Page and Previous Page and no more; "Square with words" offers those
    and Inspect Image: Square with words; the picture without words, one move forward from
    "Nameless picture", those and Inspect Image; and the table's row those, Select Table
    Text: Left cell, Select Table Text: Right cell jump and Follow Table Link: Right cell
    jump. In continuous scroll each offers the same without the two page turns, so a line of
    words and the link offer nothing: the rotor has no Actions setting on them
    (`rotor=Actions` ends in `MISSING`). No item offers a picture or a link that is not its
    own, or "Verification link", which is in the book's first section. On a device, choose
    Inspect Image on a picture and double-tap, and the inspector opens; choose Next Page on a
    line of a page and double-tap, and the page turns. After that turn the item under the
    cursor is the first line of the page shown, "Below line 18." on an iPad, and offers
    what that line does: turn the page from the link, from "Square with words" and from the
    row, and step through the rotor each time. It reads "Previous Page", "Activate Default"
    and "Next Page" and nothing of the item it was, and a double tap on "Activate Default"
    follows no link and opens no inspector.
13. Attachments in a table cell, on a Mac, in a window 600 points wide at 17 points, with
    the reader opened at the section of entries (`"launch=-SampleHref OPS/entries.xhtml"`).
    Three `right` steps from the text's first line reach the table's first row, "Upper part
    closes. Lower half opens., Sum x squared stated. grou…" in a transcript, and `in` there
    says "In", the row's words, "group 2 items" and the first cell's text, of which a
    transcript has "In Upper part closes. Lower half opens., Sum x squared stated. g…". At
    four seconds a key the next step comes before VoiceOver has said the cell's "Separator",
    which followed "In Table row group 2 items text Upper part closes." while a row was
    called "Table row". The other rows are "Drawn Blue entry square shown., Parked entry
    words. Seen entry w…", "Ornament passed., Undescribed stands. group" and "Inner one
    Inner two, Beside the inner grid. group": a described picture's words, a formula's and
    a hidden label's are in the row's name, and decoration and a picture nobody describes
    are not.
    Inside that cell VoiceOver says "Upper part closes.", "Separator", "Lower half opens." by
    line and with `readall`, and by word "Separator" between "closes." and "Lower". In the
    cell beside it: "Sum x squared image stated.", and "x squared image" by word. In the
    second row: "Drawn Blue entry square image shown.", and "Blue entry square image" by
    word; then "Parked entry words. Seen entry words.", the hidden label first. In the
    third: "Ornament passed.", with one step by word that has no phrase, for decoration;
    then "Undescribed image stands.", and "image" by word. In the fourth, whose first cell
    holds a table: "Inner one Inner two". After the table, in the page's own text, "Beyond
    them y cubed image ends.": a formula is read in a cell as it is outside one. In
    continuous scroll the first row's cell reads the same. A reader whose cells keep none of
    their elements says nothing in each of those places: a phrase with nothing in it by line
    and with `readall`, and a step with no phrase by word.
14. Page actions, on a Mac, in pages (one column in a window 600 points wide at 17 points,
    two in one 1100 wide at 23) and in continuous scroll, with VoiceOver brought to a column
    by `ax:focus=search ax:focus=0`. `ax:actions` gives each text area `AXShowMenu` and two
    actions in quotation marks, "Next Page" and "Previous Page" in pages and "Scroll
    Forward" and "Scroll Backward" in continuous scroll, and the same after
    `"ax:press=Continuous Scroll"` and `ax:press=Paging` with the reader open. On the column
    and after `in`, `actions` says "Actions menu 3 items" and three `listdown` steps say
    "Previous Page", "show menu" and "Next Page", or the scroll's two names around "show
    menu". After two moves by line, `"listchoose=Next Page"` gives `AXValueChanged` with the
    next page's words, VoiceOver says the action's name and the page's first word, and
    `describe` and `line` give "Line 1" and the page's first line; `"listchoose=Previous
    Page"` comes back the same way. In continuous scroll `"listchoose=Scroll Forward"` moves
    `SELECTION` to the first line of the next screen, which `line` reads, and "Scroll
    Backward" to where it was. In two columns, chosen inside the right-hand column
    (`ax:focus=1`), Next Page turns the spread and VoiceOver says "text" and the first words
    of the new left-hand column: `describe` gives "text is in the VoiceOver cursor", and
    `in` and `line` the column's first line. `pagedown` there does the same. A reader
    without that left VoiceOver on the first line of the new right-hand column. VoiceOver
    says "actions available" only before its hint for the text area, "actions available You
    are currently on a text area", and after no line of five moved to. A step in continuous
    scroll made straight after `in`, with `pagedown`, with `"listchoose=Scroll Forward"`,
    with `"ax:action=Scroll Forward"` or with `ax:next`, holds as one made after two moves
    by line does: two `AXSelectedTextChanged` at the new first line and none after them,
    VoiceOver says the word before that line and "text  word:" with the line's first word,
    and `describe` and `line` give that line. "text  word:" with a word of the line
    VoiceOver had entered at, and then a `SELECTION` back up the book, is the failure of a
    reader that tells of the insertion point once. Hear it in a reader launched in
    continuous scroll and in one changed to it while open, and there with nothing focused
    first (`"ax:press=Continuous Scroll" ax:focus=0 in pagedown`): where a column had
    keyboard focus before the change, the step held without the second notice. `ax:action`
    reports -25200 for the scroll's two actions though they scroll, which is AppKit's
    answer and no failure of the step
    ([#465](https://github.com/vocaro/EPUBLib/issues/465)).
15. Links in a table's cells on a Mac, in pages and in continuous scroll, on the fixture's
    last section (`-SampleHref OPS/cells.xhtml`). `ax:links` gives each cell's link by what
    it says, "worded jump", "Described entry jump, image", "image", "Entry jump with
    decoration" and "Parked entry jump", none by U+FFFC, and the page's `CHILD` lines hold
    the same five. Inside a cell, reached through its row, VoiceOver reads "worded jump" as
    its words and nothing else, and says "hyperlink Described entry jump, image",
    "hyperlink image", "hyperlink" before "Entry" and "hyperlink Parked entry jump", by word
    and in the cell's line. `nextlink` there says the cell's link by its name and
    "hyperlink". `activate` from there, from a word of the link's line and from a picture
    reached by word shows the page with "Link target reached". From the page's text
    `nextlink` goes through the five in order and begins again with the first, and
    `activate` follows the one it is on.
16. A table's text selected, on an iPhone and iPad, with the sample's selection line under
    the reader (`TEST_RUNNER_VOICEOVER_LAUNCH='-SampleSelectionLine YES'`). On a cell of the
    tables of data, choose Select Cell Text in the rotor (`choose=Select Cell Text`) and
    double-tap. VoiceOver reads the cell again as selected, "selected Alder Row header Row 2
    Column 1"; `state` says "Selected: Alder. Used: nothing."; and a screenshot shows the
    cell's words on the tint of selected text. One step on, the rotor offers Copy, then Use
    passage, which is the sample's selection action. With Use passage chosen a double tap
    brings `state` to "Selected: Alder. Used: Alder.". Deselect Cell Text stands where Select
    Cell Text stood; chosen and double-tapped, VoiceOver reads the cell without "selected",
    the tint is gone and `state` says "Selected: nothing.". A touch on another cell and back
    says "selected" again while the words are selected. The same on a row of a table that
    is not data, with Select Table Text and Deselect Table Text and the cell's words after
    each: VoiceOver reads the row as selected, and the tint is on that cell alone. In pages
    and in continuous scroll. Copy is heard to be offered and is not performed on a device,
    whose clipboard is its owner's; the unit tests perform it. With VoiceOver off
    (`TEST_RUNNER_VOICEOVER_OFF=1`), `press=Alder` selects the word by touch: UIKit draws
    it, with its handles and once, and the edit menu has Copy. In continuous scroll do both
    in the section the book was opened at (`TEST_RUNNER_VOICEOVER_HREF=OPS/grids.xhtml`)
    with nothing scrolled first, which is where the cells once had no text views
    ([#472](https://github.com/vocaro/EPUBLib/issues/472)): the line must say "Selected:
    Alder." and not the row's three cells, and `touch=Reopened` must bring "Link target
    reached" on screen.
17. Restore all original VoiceOver/scripting settings and independently verify restoration.

Keep logs and `.xcresult` bundles under `.build/voiceover/`, and export text attachments and
take screenshots as the shared guide on recording speech evidence, above, describes:

```sh
xcrun xcresulttool export attachments --path PATH_TO_SESSION.xcresult \
  --output-path .build/voiceover/evidence --filter '*.txt'
```

The committed diagnostic probe takes no screenshots. The Mac runner's transcript is plain text
and needs no export.

### Harness pitfalls and current results

- The Mac's text keys, and why the runner sends keys through System Events and uses
  `currentSpeech()` alone, are in
  [key commands](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#key-commands)
  and
  [speech capture and the key driver](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#speech-capture-and-the-key-driver);
  the speech service's 64 characters, its repeated phrase recorded once and the hint after a
  move are in
  [harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes).
  `ERROR 3` records that VoiceOver had nothing to say. The original `word0012…` capture was
  the rest of the first line after a focus click, and clicks near the left edge also turned
  back a page: use `ax:focus`.
- VoiceOver keeps its own text cursor for a column it rests on
  ([VoiceOver enters a text view at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point));
  `firstword` returns to the first visible word, and neither its return to its own offset
  after a page change nor a resize's move to the window's first control is a page-boundary
  failure. It kept one for a column it had left too, until the canvas posted its layout change
  from the element that holds the columns ([#337](https://github.com/vocaro/EPUBLib/issues/337)).
- A session that ends under an open rotor leaves VoiceOver on
  ([#399](https://github.com/vocaro/EPUBLib/issues/399);
  [VoiceOver state and restoration](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#voiceover-state-and-restoration)).
  On 2026-10-13 [hosted
  sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1, macOS 27.0.1), in
  pages in a window 600 points wide at 17 points, at the fixed pause, ended so twice at
  `75272d3` (runs 38333839407 and 38333848757): after `ax:focus in rotor` on the first page,
  whose list holds one heading, and after fourteen `ax:next` steps and `ax:lines ax:focus in
  nextheading rotor listchoose line` on a page with no heading, where VoiceOver said "No items
  in Heading menu" and then nothing to Return or to Control-Option-L. Each ended in
  `NOT_RESTORED` with exit status 126, its transcript written, and VoiceOver was still on when
  the job ended. With `listclose` before the end of the same steps VoiceOver went back to the
  text on both pages, saying "Closing Heading menu" over the list of one, `line` read the line
  it had been on, and VoiceOver switched off. At `753999e` (run 38334200030) the runner closed
  the rotor itself: the session on the page with no heading ended with the runner's
  `listclose`, "Closing Heading menu" and VoiceOver off, exit status 0. An Escape sent after
  `listchoose` had moved VoiceOver to the first page's heading, with no rotor open, drew no
  speech and no event from the reader, and `line` read the heading again. The day before, the
  same steps on the page with no heading had ended two sessions (runs 38321608082 and
  38322808793) with a traceback and no transcript, the restore having failed ahead of the
  lines that write one. Nobody listened, and no workstation was used.
- `ax:width` is a live resize, and until
  [#479](https://github.com/vocaro/EPUBLib/pull/479) a session launched in
  continuous scroll and then resized did not begin at the top of the book. Setting a window's
  size through the accessibility API takes it through AppKit's live resize, and AppKit's text
  view scrolls itself when one ends ([the native viewer](native-viewer.md), "Continuous
  scroll";
  [AppKit and UIKit text views scroll themselves](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#appkit-and-uikit-text-views-scroll-themselves);
  [offscreen AppKit hosting](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#offscreen-appkit-hosting)).
  Hosted sessions on 2026-10-13 (`-SampleFlow scrolled`, then `ax:width=600`, on a
  reader of [#473](https://github.com/vocaro/EPUBLib/pull/473) that logged each scroll with
  its stack, run 38378765133) saw the clip view go from 0 to 48 under
  `-[NSView _endLiveResize]` and `-[NSTextView viewDidEndLiveResize]`, the insertion point
  follow to character 27 a moment later, and `in` read the book's second line. Every
  transcript of such a session from before the change begins a line down, with the title
  above the screen; a session that changed to continuous scroll after its resize began at
  the top. The same scroll is made in a unit test with no assistive client, by a window
  resized with animation, which ends in the same two calls
  (`ScrolledLiveResizeTests`): 48 points at the top of a book, 114 under a toolbar, and
  back to the start of a paragraph anywhere else, 279 and 304 points in the tests' prose
  and further at each resize. With the change the
  tests' reader stays at the top, and so did a hosted session's. On 2026-10-13 at `4b046fb`,
  the change's last commit, whose code is what merged (run 38420816777, with the image,
  macOS and Xcode of run 38380968267, which is `593b907` from before the change), four
  sessions were launched in continuous scroll and resized to 600 points wide, at 17 points
  and a fixed pause of four seconds. After the resize each had `SELECTION 0,0` and the
  title as its `ENTRY`, where each of the earlier run's nine had `SELECTION 27,0` and the
  second line. `in` read "In text Page boundary verification",
  where it had read "In text Read the numbered words…", `line` the title and `describe`
  "Line 1", and the same after `ax:width=700 ax:width=600`. With the steps of one of the
  earlier sessions, `nextline` read the title and then the second line, and `pagedown`
  went to line 15, "word0061", where it had gone to line 18, "word0079": a transcript from
  before the change is a line later at its start and three after a screen's step. Away from
  the top one session was heard, and it ended a line up. After two `ax:next` the insertion
  point was on the line of "word0178", and after `ax:width=700 ax:width=600` on the line
  above it, "word0171", which `in` and `line` read. The paragraph begins 28 lines above
  that. Not looked at: whether the line is lost to the reader's own rule for text wrapped
  to another width and back, or to what is left of AppKit's scroll
  ([#500](https://github.com/vocaro/EPUBLib/issues/500)). `ax:lines` shows none of
  this: in continuous scroll it lists the text area's first 500 lines, whatever is on
  screen, and the place is in `SELECTION` and `ENTRY`. Nobody listened. Not made: a drag of
  the window's edge with a mouse, which ends a live resize the same way.
- On 2026-10-11 the Mac sessions verified first and last lines, word order, end of text,
  line counts and page-turn continuity in one and two columns at 17 and 23 points, with value
  notifications for page turns, text-size changes and resizes. See the
  [Mac verification](https://github.com/vocaro/EPUBLib/issues/55#issuecomment-6159294286). The same day a physical iPad and iPhone
  passed reading order, page boundaries and VoiceOver-activated page turns in both
  orientations at 17 and 23 points; see the
  [iPad and iPhone verification](https://github.com/vocaro/EPUBLib/issues/28#issuecomment-6159294047).

  Three things those Mac sessions left as VoiceOver's own, a resting cursor's place after a
  page change and after a window resize, with and without the reader's layout change, and a
  word broken across lines without a hyphen read whole ("…at the next num", then "numbered
  word."), are in the knowledge article linked above.

  Three things the device sessions did not cover. VoiceOver's three-finger scroll: XCTest
  cannot perform it, and its synthesized Control-Option-Space and Option-arrow keys did not
  reach VoiceOver, so the scroll keeps its API regression coverage. XCTest's downward flick
  did not register as a rotor gesture on the iPhone in landscape, while upward and sideways
  flicks did; the actions were chosen there with the upward one. And a word hyphenated
  across lines is spoken as two fragments, "must re" and "sume at the next numbered word." at
  19 points, since each line is its own item.

- On 2026-10-12 three Mac sessions heard continuous scroll at 23 points in a 600 × 882 window,
  with the insertion point kept on screen. On opening: "In text Page boundary verifica". A
  first entry after two Scroll Forward steps: "In text word0072 word0073 word0074 word0075
  word0076", the `ENTRY` line. Page Down while interacting: `SELECTION` at the new first line,
  then "word0141 word0142 word0143 word0144 word0145" for `line`. After leaving the text, two
  Scroll Forward steps and returning: "In text word0072…" with the reader's layout change;
  without it, VoiceOver's own previous line, "In text word0146…", with the view scrolled back
  to it. On each of the reader's moves VoiceOver says the word before the insertion point
  ("word0071") and repeats the item under its cursor. Read All went on in order, moving the
  insertion point sentence by sentence; the numbered paragraph has no full stop, so the view
  jumped to its end. With the VoiceOver cursor resting on the text area during a move, and no
  layout change, entering went to the first visible character by AppKit's account, the
  numbered paragraph's first line. Not heard: that resting case with the layout change,
  scrolling by hand, contents navigation, a change from paging, a book of ordinary paragraphs.
- On 2026-10-12 [hosted sessions](#hosted-mac-sessions) on `xcode-27` (macOS 27.0.1, windows
  850 points high) heard the page boundary in both layouts. Two columns at 23 points: "In text
  word0093 word0094 word0095 word0096", a right column ending at `word0228`, "2 updated items"
  for a Next Page activated through VoiceOver, then "In text word0229 word0230 word0231
  word0232" and "word0233 word0234 word0235 word0236". One column at 17 points, with
  `advance_after` at 0.5: "In text word0055…", a last line "word0165…word0171" followed by "end
  of text", then "In text word0172…" after the turn. Continuous scroll at 23 points in a
  600-point window entered at "In text word0072 word0073 word0074 word0075 word0076" after two
  Scroll Forward steps, as on the workstation. With the banner's launch agent left loaded on
  purpose, one session of four heard "application Automation Running" and was stopped
  ([speech capture and the key driver](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#speech-capture-and-the-key-driver)).
- On 2026-10-12 [hosted sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1,
  macOS 27.0.1) heard VoiceOver come back to a column after a page turn, on `740c073` and with
  the fix of [#337](https://github.com/vocaro/EPUBLib/issues/337), at the fixed pause. Two
  lines were moved in the column before leaving it. `740c073` set the insertion point to the
  offset it had before the turn and read from there: "In text word0237 word0238 word0239
  word0240" on a left column starting at `word0229`, "In text word0305…" on a right one
  starting at `word0297`, and in one column at 17 points "In text word0179…" on a page starting
  at `word0172`. The fix set none and said "In text word0229 word0230 word0231 word0232", "In
  text word0297…" and "In text word0172…". Previous Page, and Larger Text chosen from one item
  away, went the same way on each. Page Down and Page Up while interacting read the new first
  line, and continuous scroll entered at "In text word0072 word0073 word0074 word0075
  word0076", as before. With the cursor resting on the column during the turn both said "In
  text word0237…". The
  [Mac verification](https://github.com/vocaro/EPUBLib/issues/55#issuecomment-6159294286) has
  each case, under "Coming back to a column after a page turn".
- On 2026-10-12 hosted sessions on the same image, at the fixed pause, heard what a review of
  that fix had left open ([#373](https://github.com/vocaro/EPUBLib/issues/373)). With the
  sample's controls in the window's toolbar and two lines moved in the left column: `740c073`
  came back at "In text word0237 word0238 word0239 word0240" after a native press of Next Page
  from one item away; the fix said "In text word0229 word0230 word0231 word0232" there, with
  VoiceOver's cursor on the toolbar during the press, and with Next Page activated through
  VoiceOver inside the toolbar. In continuous scroll on `1b7bf07`, where the window still
  posts, VoiceOver brought to the text by a focus change entered at the new first line, "In
  text word0131 word0132 word0133 word0134 word0135", after Scroll Forward activated from
  eight items away and after a native press from one item away: that flow did not have the
  fault.
- On 2026-10-12, continuous scroll on a physical iPhone 17 Pro Max (iOS 27.2, 440 × 956,
  17 points) and iPad Air 13-inch (iPadOS 27.2, 23 points), the book of ordinary paragraphs,
  through XCTest's VoiceOver service with VoiceOver switched on for each session; its phrases
  were recorded and nobody listened. Before the scroll view listed its lines, two Scroll
  Forward steps on the iPhone left `p003w01` to `p008w40` on screen, and the ninth move
  forward from Scroll Forward gave "C hapter one", then the whole of `p001`, with the reader
  back at the top of the book ([#301](https://github.com/vocaro/EPUBLib/issues/301)).
  With the lines listed, on the iPhone: after two steps the first line of the reading area
  was `p005w21 … p005w25`, the fifth of its paragraph, and the ninth move gave that line; the
  screenshots before and after it differ only in VoiceOver's cursor. `backward=1` returned to
  Bookmark. Twenty-eight moves forward and forty back gave every line once and in order, the
  view following, back past the line VoiceOver came in at to `p004w01`. After
  `activate=Contents,activate=Chapter two` the fifth move from Contents gave "Chapter two",
  twenty-four more read on past the last line that had been on screen, and thirty back
  passed the heading into the chapter before. A touch on Bookmark left the twenty lines on
  screen listed alone, `point=0.5:0.8` gave the line under it, and twenty-two `flick=right`
  and twenty-eight `flick=left` read on and back as the service's moves had.
  On the iPad upright (1024 × 1366): after two steps the ninth move gave `p010w15 … p010w21`,
  the third line of its paragraph and the first of the reading area; forty-four moves
  forward and sixty back gave every line once and in order. In the first book at 23 points
  the lines read "Page boundary verification", "Verification link Link", ". Image:", "Blue
  verification square Image", and after three steps the ninth move gave `word0550 …
  word0555`, the first on screen.
- The same day, with the scroll view listing the lines on screen alone, on the iPad on its
  side (1366 × 1024), straight after `activate=Contents,activate=Chapter two`: the fifth move
  gave "Chapter two" and the moves after it the lines down to `p043w36 … p043w40`, the last
  that had been on screen when the menu closed. The next gave "Vertical scroll bar" and the
  one after the sample's footer; the lines after `p043w40`, listed by then, were passed
  over. Moving back from there gave the lines in order to "Chapter two", then three of them
  a second time, then went on above the heading without a gap. An iPhone 17 Pro simulator
  (iOS 27.0) did the same after any menu closed, even when the chapter chosen was the one on
  screen, and read on, as the devices did, when VoiceOver came into the text after a step of
  the reader's own or without a menu having closed. Posting a layout change, with no element
  or with the line under the cursor, did not change that in the simulator (the entry on
  [#428](https://github.com/vocaro/EPUBLib/issues/428) below has what a replay showed); a
  page-scrolled notification made VoiceOver skip lines; giving it new elements for the same
  lines once its cursor had moved on made it lose its place
  ([#339](https://github.com/vocaro/EPUBLib/issues/339);
  [UIKit's own text view elements are every paragraph](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikits-own-text-view-elements-are-every-paragraph)).
- What VoiceOver asks for, from a build that logged UIKit's answers to it (not committed; it
  replaced `_accessibilityElementsInDirectionWithCount:options:` to log the count and what
  came back, as
  [VoiceOver's vot log](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-simulator.md#voiceovers-vot-log)
  describes), in the simulator and on the iPad alike
  ([VoiceOver moves through a cache of the items around its cursor](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-moves-through-a-cache-of-the-items-around-its-cursor)).
  As its cursor lands on an item it asks
  for the two items after it and the two before; at each move after that, for the one item
  beyond those it holds. At its first move after a menu has closed it asks for fifty each
  way and goes through them without asking again, then goes back to one at a time. With the
  lines on screen listed alone, the fifty after Contents were four controls, those lines,
  the scroll bar and the footer. It goes through the same fifty after a touch on one of
  them: in the simulator after the menu, `activate=Scroll Forward` and eight moves went
  through the controls it had been given, the ninth said "Chapter one", a line no longer
  listed, and the tenth was Scroll Forward again, from where it asked afresh. UIKit's hit
  test of the text view reads every element listed, twice at each move, and so does XCTest's
  snapshot. The scroll view measured a list of some 120 lines in about 11 ms on the iPad and
  5 ms in the simulator, in debug builds, a little more than once a move.
- With the fifty lines after the screen listed, and fifty each side while the cursor is on a
  line, the same day, through XCTest's VoiceOver service, VoiceOver switched on for each
  session and off after it; nobody listened. The iPad's two sessions were run at `667b110`
  and again at `b2760c6` and `bcc55f3`, each with main merged in, with the same phrases but
  for "Chapter two Heading" once main had headings as elements. iPad on its side at 23
  points,
  `rotate=landscape,activate=Contents,activate=Chapter two,wait=2,visible,screenshot,forward=5,screenshot,forward=62,visible,backward=72,visible,rotate=portrait`:
  the fifth move gave "Chapter two", the sixty-two after it every line once and in order
  from `p041w01` to `p051w08 … p051w14`, past `p043w36 … p043w40` to `p044w01` and on with
  no scroll bar among them, and seventy-two back every line in order to `p039w21`, through
  the heading into the chapter before. The first `visible` counted 68 numbered lines, those
  on screen and the fifty after them. The screenshots before and after the fifth move
  differ only in VoiceOver's cursor, and in one run the status bar's clock. iPad upright, the two-step session above with forty
  moves forward and fifty-six back: the ninth move gave `p010w15 … p010w21`, as before the
  change, with every line once and in order both ways, and the screenshots before and after
  coming in differ only in the cursor. With an earlier build that listed the same lines,
  twenty-seven of VoiceOver's own flicks after the menu on the iPad on its side
  (`flick=right*27`) gave the four controls, the heading and twenty-two lines in order to
  `p044w22 … p044w28`. iPhone 17 Pro simulator (iOS 27.0), at `667b110`: after
  `activate=Contents,activate=Chapter one`, seventy lines forward from `p001w01` to
  `p008w22`, in order, where it had stopped at `p002w29 … p002w33`, and sixty-nine back to
  the heading in order. In one run of two the service gave a phrase twice where
  `p004w39 p004w40` was due, on a move that took 2.4 s with the Mac's load average at 750.
  The two-step session, a touch on Bookmark, `point=0.5:0.8` and six and eight flicks: in
  order.
- Coming into the text from below, the same day at `667b110`, from the sample's footer
  (`touch=VoiceOver Paragraph,backward=6`). At the top of the book, in the simulator: the
  scroll bar, the last line on screen and the lines above it in order. Further in, on the
  iPad upright after two scroll steps and in the simulator: the scroll bar and then
  Bookmark. With an earlier build, on the iPad on its side after a menu and a walk through
  the text: "Vertical scroll bar", `p045w15 … p045w21`, the last line on screen, then
  Bookmark. The
  logging build showed the scroll view 88 points back by the time VoiceOver asked for the
  line before the one it had been given: UIKit scrolls the scroll bar into view as it does
  a line, by the 48-point top inset and 40 more, and the line was then below the screen and
  not listed ([#367](https://github.com/vocaro/EPUBLib/issues/367)). The scroll view has
  listed the lines on screen alone there since #301, and this is not changed. A first
  attempt listed the fifty lines before the screen there as well, to mirror the lines after
  it; the move back went wrong in the same way, and they were taken out.
- With the list keeping its last line while VoiceOver's cursor is after the text
  ([#367](https://github.com/vocaro/EPUBLib/issues/367)), the same day at `916e4cd`,
  through XCTest's VoiceOver service, VoiceOver switched on for each session and off after
  it; nobody listened. On the physical iPad Air 13-inch (M3), iPadOS 27.2, at 23 points in
  the book of ordinary paragraphs, each session ended with `touch=VoiceOver Paragraph` and
  moves back:
  - Upright after two scroll steps, 44 moves: "Vertical scroll bar", `p015w15 … p015w21`,
    the last line in the reader's view, and 42 lines above it once each and in order to
    `p008w20`, past `p010w15`, the first that had been on screen; then six forward in order.
  - Upright after fifteen scroll steps, 46 moves: the scroll bar, `p078w36 … p078w40` and 44
    lines above it in order to `p071w22`, past `p074w01`.
  - Upright at the end of the book
    (`activate=Contents,activate=Chapter three,wait=2,activate=Scroll Forward`, the button
    dimmed), 46 moves: the scroll bar, `p086w36 … p086w40`, the book's last line, and the
    lines above it in order through "Chapter three Heading" to `p079w29`, past `p082w08`.
  - On its side after two scroll steps, 40 moves: the scroll bar, `p010w22 … p010w28` and 38
    lines above it in order to `p004w07`, past `p007w08`.
  - On its side at the end of the book, 40 moves: the scroll bar, `p086w36 … p086w40` and
    the lines above it in order through the heading to `p080w28`, past `p083w36`.

  The upright session at the end of the book was run thirteen times. Twelve read every line
  in order, 11 to 44 of them. In the first of the thirteen, four lines up, after
  `p086w15 … p086w21`, the next move gave "Open EPUB… Button", the first item on the screen,
  and VoiceOver's cursor stayed there. Seven of the twelve were then run with the logging
  build to catch it, and none did: the cause is not known. The log could be fetched from
  four of the seven, and in those the lists were thrown away at launch and never after.
  It has the change at work: a list of 29 lines ending at `p086w36` as the cursor came to
  the footer; the view 88 points back at the move to the bar, and a list of 31 from the
  new first line on screen to the same element for `p086w36`, so that the line before it
  was `p086w29`; then UIKit bringing `p086w36` back into view before the cursor came to
  it. VoiceOver asked for two items as its cursor landed and one at each move, and twice
  for ten after the menu; it did not ask for fifty.
- The same change in simulators of the session's own (iOS 27.0), the iPhone 17 Pro at 17
  points. The issue's steps,
  `activate=Scroll Forward,activate=Scroll Forward,wait=2,visible,touch=VoiceOver Paragraph,backward=30,visible,forward=8`:
  before the change "Vertical scroll bar" and then "Bookmark"; with it the scroll bar,
  `p006w01 … p006w04`, 28 lines above it in order to `p003w05` and eight forward. The log:
  the view at 775 and a list of 18 ending at `p006w01`; at 687 a list of 20, from
  `p004w01` to `p006w01`; then UIKit taking the view to 962 for `p006w01`, where the screen
  held the line VoiceOver asked from next. With the footer touched a second time after one
  move to the bar (`…,backward=1,wait=1,touch=VoiceOver Paragraph,backward=7`) the view
  went back 88 points at each move to the bar, to 599, with `p006w01` still the last of 24
  listed, and the lines were read in order from it. At the end of the book: before the
  change the scroll bar, `p086w40` and Bookmark; with it the scroll bar, `p086w40` and
  eleven lines above it in order. After a menu
  (`activate=Contents,activate=Chapter two,wait=2,touch=VoiceOver Paragraph,backward=26`):
  the scroll bar and 24 lines in order through "Chapter two Heading" into the chapter
  before. The two-step session and the menu session of #339 read on and back in order as
  before. On the iPad Air 13-inch (M4) simulator at 23 points, 44 moves back gave the
  scroll bar and 40 lines in order, with three moves that took over two seconds and gave
  the phrase before them again, at a load average of 860; no line was missing.
- The scroll bar itself, in the simulator's log, and not changed by #367
  ([the scroll indicator is a supplementary header that breaks reading order](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#the-scroll-indicator-is-a-supplementary-header-that-breaks-reading-order)).
  UIKit asks the
  scroll view for the bar's place with `index(ofAccessibilityElement:)` and gets
  `NSNotFound`, from UIKit's own implementation as from the reader's. Asked for the item
  before the bar it then gave Bookmark, and for the item after it the first line listed.
  So forward past the book's last line
  (`activate=Contents,activate=Chapter three,wait=2` and three scroll steps,
  `point=0.5:0.6,forward=14,backward=8`): `p086w40`, "Vertical scroll bar", then
  `p085w01`, the first line on screen, and on down the screen a second time; and back from
  there the scroll bar and then Bookmark, not `p086w40`
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)). The bar's accessibility frame was
  the height of the scroll view, which is why UIKit moves the view for it: the top inset
  cuts it.
- The scroll bar's place among the lines
  ([#342](https://github.com/vocaro/EPUBLib/issues/342)), 2026-10-12 and 13, through XCTest's
  VoiceOver service; nobody listened. Simulators of the session's own on iOS 27.0, the
  iPhone 17 Pro at 17 points and the iPad Air 13-inch (M4) at 23, in the book of ordinary
  paragraphs. A build that logged UIKit's requests and its own enumeration of an item's
  neighbours (not committed) showed why the bar stood where it did:
  - The scroll view's `_accessibilitySupplementaryHeaderViews` held the vertical bar. Asked
    for the item after the bar, UIKit enumerated from the reader's canvas, a child of the
    host's view, with the bar as that child's header 0, and gave the canvas's first leaf:
    the first line listed. Asked for the item before, it gave the child before the canvas,
    Bookmark. `index(ofAccessibilityElement:)` was asked for the bar only as an attribute
    of the bar, as VoiceOver's cursor went to it, and never while UIKit looked for the
    bar's neighbours: answered with one past the last line, the transcript was unchanged.
  - With the bar's `accessibilityElementsHidden` set, the header list was empty, and UIKit
    asked the scroll view for the bar's index and enumerated from there. An index equal to
    the count gave the sample's footer as the item after and still Bookmark as the item
    before; with the bar listed at that index, the last line. A bar hidden from the start
    was never read: the last line, the footer, and back.
  - The bar hidden and listed from that first question until the cursor was elsewhere read
    every session right, the physical iPad Air 13-inch (M3) on iPadOS 27.2 among them, on
    2026-10-12 at `3fa3121`, VoiceOver switched on for each session and off after it. At
    the end of the book, upright: `p086w36 … p086w40`, "Vertical scroll bar, 15 pages 99%",
    "VoiceOver Paragraph Verification", where VoiceOver stayed; back, the bar, the last
    line and six lines above it in order; forward the same. On its side the same with 22
    pages, and from a touch on the bar the last line and three above it. It was dropped
    all the same. It rested on VoiceOver asking for the bar's index before anything else,
    the view still went back 88 points at every move to the bar, and in one simulator
    session of six a touch on the bar took VoiceOver's cursor to the bar and, 150 ms
    later, to the line under the finger: hidden, the bar was no longer what the finger
    was on.

  With the bar hidden for good and the reader's own element listed for it, at `9a2ce50`,
  in the simulators:
  - iPhone, the end of the book
    (`…,point=0.5:0.6,forward=12,backward=8,forward=10,point=0.955:0.6,backward=5,forward=8`):
    nine lines to `p086w40`, "Vertical scroll bar, 41 pages 100%", "VoiceOver Paragraph
    Verification" twice; back, the bar, `p086w40` and six lines above it in order; forward,
    the same lines, the bar and the footer; from the touch on the bar, `p086w40` and four
    above it. The view's offset did not change once in the session. It went back 88 points
    at each move to UIKit's own bar, which is why that bar read 99%.
  - iPad, the end of the book (`…,touch=p086w36,forward=3,backward=8,forward=10,point=0.982:0.6,backward=4,forward=6`):
    the same, with "15 pages 100%".
  - Mid-book from below, step 8's session with touches on the bar added
    (`…,touch=VoiceOver Paragraph,backward=30,visible,forward=8,point=0.955:0.6,backward=6,forward=9,point=0.955:0.6,forward=2`):
    the bar, `p006w01 … p006w04` and 29 lines above it in order, eight forward; from the
    bar by touch, `p004w31` and five above it; and the footer after the bar. On the iPad
    44 moves back from the footer gave the bar and 43 lines in order from `p015w22`.
  - The top of the book, the two-step session and the menu session of step 7: in order as
    before, with no scroll bar among the lines.
  - Eight touches down the bar's place after two scroll steps (`point=0.955:Y` for Y from
    0.45 to 0.8). On main: the bar eight times. With the element and the lines listed
    whole: the bar five times and a line three times, each a five-word line ending 6
    points from the finger. With the lines listed clear of the bar: the bar eight times,
    and at `point=0.93:0.7`, where a full line's frame used to reach, the bar. At
    `point=0.955:0.4`, under the top inset, main gave the bar and the element is not
    there.
  - Adjusting the bar (`point=0.955:0.6,flick=down`) read the new value, "13%" or "15%",
    with the view some three screens on, and VoiceOver's cursor still on the bar. Moving
    back from there gave the last line on screen and the line above it, and at every
    further move back VoiceOver stayed on that line, in three sessions of three; moves
    forward went on. The log has the line it asked the index of as the element listed,
    on screen, and nothing after the question. The iPad did the same, and the cause is in
    the entry on the stop after an adjustment (both below). With UIKit's own bar the same
    flick read nothing and left the cursor on no item, in the one simulator session that
    tried it.

  The same element on the physical iPad Air 13-inch (M3), iPadOS 27.2, at 23 points, on
  2026-10-13 at `b5e135f` (the simulator sessions' code with main merged in), VoiceOver
  switched on for each session and off after it, and the transcripts passed through a
  filter that keeps the book's and the sample's words alone:
  - Upright at the end of the book
    (`…,touch=p086w36,forward=3,backward=8,forward=10,point=0.982:0.6,backward=4,forward=6`):
    `p086w36 … p086w40`, "Vertical scroll bar, 15 pages 100%", "VoiceOver Paragraph
    Verification" twice; back, the bar, the last line and six lines above it in order;
    forward, the same lines, the bar and the footer; from the touch on the bar, the last
    line and three above it, and forward to the bar and the footer. The bar read 99% in
    the dropped attempt's sessions, with the view 88 points back for it.
  - On its side, the same steps between `rotate=landscape` and `rotate=portrait`, with
    `point=0.987:0.6`: the same, with "22 pages 100%". The phrase at the turn to landscape
    was not one of the book's or the sample's and was withheld unread, as in the session
    of the day before.
  - Upright after two scroll steps
    (`…,touch=VoiceOver Paragraph,backward=12,forward=5,point=0.982:0.6,backward=3,point=0.982:0.6,flick=down,wait=2,backward=5,forward=3`):
    "Vertical scroll bar, 15 pages 15%", `p015w15 … p015w21`, the last line in the
    reader's view, and ten lines above it in order; five forward; from the touch on the
    bar, `p016w08` and two above it. After the flick the bar read 27%, from 17%. The
    phrase at the flick itself was withheld: the filter knows no bare percentage. Then
    back: `p023w36 … p023w40`, `p023w29 … p023w35`, and that line again at each of three
    further moves; forward, the line after it, the bar and the footer. So the stop after
    an adjustment is the device's too.

  The stop after an adjustment was found on 2026-10-13, in an iPhone 17 Pro simulator of
  the session's own (iOS 27.0, 17 points, the book of ordinary paragraphs), from
  VoiceOver's own log ([Simulators](#simulators)) beside a build that logged every
  attribute, action and element VoiceOver asked the reader's elements for (not committed).
  Nobody listened. The steps were
  `activate=Scroll Forward,activate=Scroll Forward,wait=2,point=0.955:0.6,flick=down,wait=2,backward=4,forward=2`:
  - As the touch landed on the bar VoiceOver asked for two items each side of it. It held
    `p005w37 …` and `p006w01 …`, the last two lines on screen, then the bar and the footer.
  - The swipe is its decrement of the bar. UIKit's bar added a tenth to the view's
    progress (`accessibilityScrollIndicator:addProgress:`), 1,490 points at once, and
    VoiceOver received one notification, "Update element Visuals". It read the bar's own
    attributes again, said "15%" and asked for no item.
  - First move back: `Checking element p006w01`, which no longer answered, its element
    being gone; a request for one item before the bar, which gave `p012w16 …`, the last
    line on screen; then `fetch count: 1 -- startFromBehind: p005w37`, a request that
    reached no element of the reader's, and `retrieved:` with `BEHIND: ()`. Second move:
    `Checking element p005w37`, a request for one item before `p012w16 …`, which gave
    `p012w11 …`, and `fetch count: 0`. Third move: `Cache:` with `<null>`, `p012w11 …`,
    `p012w16 …`, the bar and the footer; `Found element: (null)`; the scroll view's own
    value and the item at its middle asked for; and `BoundaryEncountered`, with the sound
    `WrapBoundary`. The same at every further move back, and VoiceOver's own flick
    (`flick=left*5`) did the same.
  - With every listed element kept alive after it left the list, as an experiment:
    `p006w01 …` and `p005w37 …`, the two lines from before the swipe, and then "Bookmark".
  - With a layout change that names the bar's element posted after the adjustment:
    `VoiceOver Received note: Layout Changed`, `Proposing current element: Vertical scroll
    bar`, `Forced update, so removing all from cache`, `fetch count: 2` each way from the
    bar, `BEHIND:` with `p012w16 …` and `p012w11 …`, and no speech after "15%". Five moves
    back read five lines in order. A layout change that names nothing and a screen change
    did the same, the screen change with `ScreenDidChange` as well. In one session of
    seven the flick read `p004w35 …`: no adjustment had been made, the swipe having been
    taken for a touch at a load average of 630.

  With the element posting that layout change, at `02a5529`, in the same simulator:
  - The steps above with `backward=6,forward=8`: "15%", then `p012w16 …`, `p012w11 …`,
    `p012w06 …`, `p012w01 …`, `p011w36 …`, `p011w31 …`; forward, the same lines in order
    and on past `p012w16 …`, the fifty lines after the screen being listed once the cursor
    is in the text.
  - With VoiceOver's own flicks (`…,flick=down,wait=2,flick=left*5,flick=right*7`): "15%",
    five lines back in order to `p011w36 …`, seven forward in order.
  - Down, back into the text, the bar again, down and up
    (`…,flick=down,wait=2,backward=3,point=0.955:0.6,flick=down,wait=2,flick=up,wait=2,backward=4,forward=6`):
    "15%" and three lines; "Vertical scroll bar, 41 pages 16%", "26%" and "16%"; then
    `p013w11 …` and three lines above it in order, and six forward.
  - Step 10's session at the end of the book with an adjustment added
    (`…,point=0.955:0.6,flick=down,wait=2,backward=3,forward=5`): as recorded above, the
    bar at 100% each time. The flick read "100%" and moved nothing; back, `p086w40` and
    two lines above it; forward to the bar and the footer.
  - An iPad Air 13-inch (M4) simulator at 23 points
    (`activate=Scroll Forward,activate=Scroll Forward,wait=2,point=0.982:0.6,flick=down,wait=2,backward=6,forward=8,point=0.982:0.6,flick=up,wait=2,backward=3`):
    "Vertical scroll bar, 15 pages 15%" and "25%"; six lines back in order from
    `p022w08 … p022w14` to `p021w15 … p021w21` and eight forward in order; the bar again
    at 25%, "15%" for the swipe up, then `p016w08 … p016w14` and two lines above it.
  - The iPhone again with main merged in, at `a18e546`
    (`…,flick=down,wait=2,backward=6,forward=3,point=0.955:0.6,flick=up,wait=2,flick=left*4,flick=right*6`):
    "15%", six lines back in order and three forward; the bar at 16% and "6%" for the
    swipe up; four lines back by VoiceOver's own flick from `p006w27 …` and six forward,
    in order.

  The same on the physical iPad Air 13-inch (M3), iPadOS 27.2, upright at 23 points, on
  2026-10-13 at `a18e546`: VoiceOver switched on for each session and off after it, the
  iPad claimed for the runs and released, and the transcripts passed through the filter
  that keeps the book's and the sample's words, with a bare percentage let through.
  - `activate=Scroll Forward,activate=Scroll Forward,wait=2,point=0.982:0.6,flick=down,wait=2,backward=6,forward=8`:
    "Vertical scroll bar, 15 pages 15%" and "25%"; then `p022w01 … p022w07`,
    `p021w36 … p021w40`, and four lines above them in order to `p021w08 … p021w14`;
    forward, eight lines in order to `p022w22 … p022w28`. Before the change, in the
    session above: two lines, and the second three more times.
  - With VoiceOver's own flicks, and up again
    (`…,flick=down,wait=2,flick=left*5,flick=right*3,point=0.982:0.6,flick=up,wait=2,backward=3,forward=5`):
    "25%", five lines back in order from `p022w01 …` to `p021w15 …` and three forward; the
    bar at "16 pages 25%" and "15%" for the swipe up; then `p015w36 … p015w40` and two
    lines above it, and five forward in order. The session's first phrase, before any
    step, was not the book's or the sample's and was withheld unread.
- A move of the reader's own in continuous scroll, with VoiceOver holding items from before
  it ([#428](https://github.com/vocaro/EPUBLib/issues/428);
  [a layout change makes VoiceOver drop its cache about 0.8 s later](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#a-layout-change-makes-voiceover-drop-its-cache-about-08-s-later)),
  on 2026-10-13. iPhone 17 Pro
  simulators of the session's own (iOS 27.0, 17 points) and the physical iPad Air 13-inch
  (M3) (iPadOS 27.2, upright at 23 points), through XCTest's VoiceOver service, VoiceOver
  switched on for each session and read back as off after it; nobody listened. The book of
  ordinary paragraphs unless the first book is named. "Before" is main at `0a0dce0` with the
  sample's `-SampleStepAfter` added, and "after" is `812335c`. VoiceOver's own log is the
  simulator's ([Simulators](#simulators)), from builds that also logged what the reader
  posted (not committed).

  The issue's first case is the simulator's own. Its steps are
  `activate=Contents,activate=Chapter one,wait=2,forward=5,forward=18,activate=Scroll Forward,listen=2,forward=9,forward=6`.
  - Simulator, before: after the step the eight controls from "Search in book" to
    "Bookmark", then "Chapter one Heading", then "Scroll Forward" and the controls again.
    VoiceOver's log has `fetch count: 50` at its first move after the menu and sixty-one
    items held from then on, the touch on Scroll Forward landing on one of them; at the
    ninth move `Found element: Chapter one (14, 61)`, at the tenth `currentValid=0`, the
    cursor set back on Scroll Forward and `fetch count: 2`. Nothing reached it as the step
    was made.
  - Simulator, after: the eight controls, then `p003w36 p003w37 p003w38 p003w39`, the first
    line on screen, and six lines in order, with VoiceOver's own flicks as with the
    service's moves (`flick=right*12`). The log has `Received note: Layout Changed` with no
    element as the step is made, `Forced update, so removing all from cache` 0.8 s later
    and `fetch count: 2` each way from Scroll Forward, where the cursor stayed; nothing was
    said. After Scroll Backward
    (`activate=Contents,activate=Chapter two,wait=2,forward=5,forward=3,activate=Scroll Backward,listen=2,forward=10,forward=4`)
    the tenth move gave `p039w24 …`, the first line on screen, where before it gave
    "Chapter two Heading", the line VoiceOver held, which the step had taken most of the
    way down the screen.
  - iPad, before and after alike: the eight controls, then `p005w15 … p005w21`, the first
    line on screen, and six lines in order; after Scroll Backward, `p036w15 …`. There the
    double tap is VoiceOver's own, and it had asked again by itself. A simulator's double
    tap is a plain touch that VoiceOver knows nothing of, so the stale line after it is
    not a device's.
  - A link followed from its line, in the first book
    (`touch=Verification link,activate=Verification link,listen=3,forward=3,backward=5`).
    Simulator, before: nothing said, then ". Image:", "Blue verification square" and ".",
    the lines after the link, with the reader back at the top of the book. After: "Link
    target reached Heading" by itself, then "This is the end of the numbered paragraph."
    and on, and back through the heading to `word1198 word1199 word1200`; the log has the
    layout change with an element, `Will set element: Link target reached` 0.9 s later and
    the forced update. iPad, before and after alike: "Link target reached Heading" by
    itself and the same lines.

  A move VoiceOver did not make shows the fault on the iPad too. The sample makes one
  scroll step by itself (`-SampleStepAfter`).
  - The cursor on a line (`touch=p001w01,listen=30,forward=3,backward=4`, the step at 30
    seconds). iPad, before: nothing heard at the step, then `p001w08 …`, `p001w15 …` and
    `p001w22 …`, the lines after the one the cursor was on, and back to "Chapter one
    Heading": the reader had gone back with the cursor, and the step was undone. After:
    `p005w15 … p005w21` heard at the step, the first line of the new screen, then three
    lines on and four back in order, past that line to `p005w08 …`. The simulator the same
    with its own lines: before, `p001w06 …` and on; after, `p002w24 …` heard, and its log
    has the layout change naming that line, `Will set element` 0.8 s later and
    `fetch count: 2` each way from it.
  - The cursor on a control with fifty items held
    (`activate=Contents,activate=Chapter one,wait=1,forward=5,forward=3,touch=Scroll Forward,listen=40,forward=9,forward=4`,
    the step at 55 seconds). iPad, before: the eight controls, then "Chapter one Heading",
    `p001w01 …`, `p001w08 …` and on, the screen from before the step. After: the eight
    controls, then `p005w15 …`, the first line on screen, and four lines in order.
    Simulator, before: "Chapter one Heading" and back to Scroll Forward, as in the issue;
    after: `p002w24 …` and on. Without the eight moves before the touch VoiceOver held four
    items and came in at the first line on screen either way.

  What a layout change does, from the same logs.
  - With no element, and the cursor's line no longer on screen (a build that posted so
    after the link): `Will set element: This is the end of the numbered paragraph.` 1.4 s
    later, the line then drawn where the link had been, not the link's target. So a line
    is named whenever the cursor is in the text.
  - During a move by the Headings rotor
    (`touch=p001w06,rotor=Headings,flick=down,listen=3,forward=3,backward=5`): "Chapter two
    Heading" and the lines each side in order, with a layout change posted and with none.
    VoiceOver set its cursor on the rotor's item 30 ms after the notification and made its
    forced update from there. Nothing is posted for a rotor's move.
  - After a chapter chosen from the contents the simulator's VoiceOver no longer asks for
    fifty: the layout change for the chapter arrives while the menu closes, the forced
    update leaves two items each side of Contents, and the first move finds something
    held. So the issue's second case
    (`activate=Contents,activate=Chapter two,wait=2,forward=5,forward=8,backward=12`) went
    on above the heading there, `p040w39 p040w40` and three lines more, where before it
    gave "Bookmark". On the iPad it gave "Bookmark" before and after: that case stands.
  - [#339](https://github.com/vocaro/EPUBLib/issues/339)'s trial again, the lines listed as
    they were then (the screen alone from a control, two each side with the cursor on a
    line) and a layout change posted at every change of the list
    (`activate=Contents,activate=Chapter two,wait=2,forward=5,forward=30`). Without the
    layout change: the lines to `p042w29 …`, "Vertical scroll bar" and the footer, as
    recorded. With it, naming nothing or the cursor's line: on past the screen to
    `p044w14 …` in order. It was not the changes posted as the cursor moved that did it.
    Five of them arrived while VoiceOver moved on every half second, and no forced update
    followed any. It was the one posted as the chapter was shown, with the cursor at rest
    on Contents, which kept VoiceOver from asking for fifty. A chapter chosen that is the
    one already shown changes no list, and a trial on such a choice would have seen no
    effect; what the trials of the day did is not on record.
  - A search (`activate=Search in book,type=p020w01\n,listen=3,forward=12`, with a `type`
    step that is not committed) and the contents
    (`activate=Scroll Forward,wait=1,activate=Contents,activate=Chapter two,listen=2,forward=6,backward=3`)
    read the same before and after in the simulator: into the text at `p020w01 …`, the
    line of the hit, and at "Chapter two Heading".
  - On the iPad one session's first phrase, before any step, was not the book's or the
    sample's and was withheld unread.
- A page shown in paging by something VoiceOver did not do, with items of the page before
  it still held: what [#428](https://github.com/vocaro/EPUBLib/issues/428)'s change left
  for paging, on 2026-10-13. Simulators of the session's own on iOS 27.0 with Xcode 27.0,
  at 17 points: iPhone 17 Pros (402 × 874) with the book of ordinary paragraphs, and an
  iPad Air 13-inch (M4) (1024 × 1366, upright) with the first book. Through XCTest's
  VoiceOver service, VoiceOver switched on for each session and read back as off after it;
  nobody listened, and no device has run it. "Before" is `8328237`, which is main at
  `9a8e66b` with the sample's `-SampleDarkAfter` and nothing else, and "after" is
  `f822c8a`; each step list was a session of its own on each, thirty-six in all, at load
  averages from 4 to 93. The sample itself turns the page (`-SampleStepAfter`) or shows it
  again dark (`-SampleDarkAfter`), of which VoiceOver knows nothing, as it knows nothing of
  a key. The iPhone's first page holds "Chapter one" and twelve lines, and its second
  begins at `p002w19 …`. VoiceOver's own log is quoted ([Simulators](#simulators)).

  A page turned, with the cursor on a control.
  - Back on the last control after reading into the page
    (`touch=Bookmark,forward=2,backward=2,listen=25,screenshot,forward=4,visible`, the turn
    at 25 seconds). Before: nothing heard at the turn, then "Chapter one Heading",
    "Bookmark", `p002w19 …` and `p002w24 …`. The log has nothing arriving at the turn;
    at the first move `Checking element Chapter one` and `Found element: Chapter one
    (2, 5)` in one millisecond; at the second `currentValid=0`, the cursor set on Bookmark
    and `fetch count: 2`. After: nothing heard at the turn, then `p002w19 …` and the three
    lines after it. The log has `Received note: Layout Changed` with no element as the
    page turns, `Forced update, so removing all from cache` 0.8 s later and
    `fetch count: 2` each way from Bookmark, with no `Will set element` between: the
    cursor stayed. The screenshot shows the second page with VoiceOver's cursor on
    Bookmark.
  - On the page button with the whole page held
    (`activate=Contents,doubletap=VoiceOver Paragraph,wait=1,forward=5,forward=3,touch=Next Page,listen=35,screenshot,forward=9,forward=4,visible`,
    the turn at 50 seconds). The double tap closes the menu with nothing chosen, and both
    logs have `fetch count: 50` at the first move after it and thirty items held from
    then on, the touch on Next Page landing on one of them. Before: the eight controls
    from "Search in book" to "Bookmark", then "Chapter one Heading", then "Next Page" and
    the controls again; `Found element: Chapter one (14, 30)` at the ninth move and
    `currentValid=0` at the tenth, the cursor set on Next Page. After: the eight controls,
    then `p002w19 …` and four lines in order; the layout change with no element at the
    turn and the forced update 0.8 s later. `visible` gives `p002w19 …` as the page's first
    line in both.
  - The same with a chapter chosen (`activate=Chapter one` in place of the double tap).
    Before: the same failure, with `fetch count: 50`. After: `p002w19 …`, and the log has
    no `fetch count: 50` at all. The layout change for the page shown at the choice
    arrives as the menu closes, the forced update leaves two items each side of Contents,
    and the first move finds something held, as in continuous scroll after
    [#428](https://github.com/vocaro/EPUBLib/issues/428). Whether a device then asks for
    fifty is not known; an iPad did in continuous scroll.
  - Lines held that the cursor has not been on. With two each side
    (`touch=Bookmark,listen=25,screenshot,forward=4,backward=3,visible`), and with the
    whole page and one move after the menu, which goes to Appearance
    (`…,wait=1,forward=1,touch=Next Page,listen=35,screenshot,forward=9,forward=3,visible`,
    the turn at 40 seconds). Before and after alike in both: `p002w19 …` at the first
    move into the text and the lines after it in order. Before, the log has
    `Checking element Chapter one` and a few milliseconds later
    `Found element: p002w19 …`, a new item. The failure needs a line VoiceOver has been
    on.
  - The page button touched under the cursor, twice
    (`touch=Next Page,doubletap=Next Page,listen=4,doubletap=Next Page,listen=4,screenshot,forward=9,forward=2`).
    Before and after alike: nothing heard but the button, then the eight controls and
    `p004w01 …`, the third page's first line. After, the log has a layout change with no
    element at each turn and the forced update 0.8 s after each, the cursor on Next Page
    throughout.

  The same page shown again, the reader made dark 18 seconds in.
  - The cursor on the page's third line, and a near return
    (`touch=Bookmark,forward=4,listen=22,screenshot,backward=1,forward=3`). Before: nothing
    heard at the change, then `p001w06 …`, "Bookmark", "Chapter one Heading" and
    `p001w01 …`: out of the text at the second move. The log has `Found element:
    p001w06 … (3, 5)` taken as it was, `currentValid=0` at the next move and the cursor
    set on Bookmark, which the session had touched first. After: `p001w06 …`,
    `p001w11 …`, `p001w16 …` and `p001w21 …`. The log has the layout change with no
    element, and 0.8 s later `Will set element` for the line the cursor was on,
    `Forced update` and `fetch count: 2` each way from it; nothing was spoken in the
    eleven seconds until the next move. The screenshot shows the page dark with the
    cursor on that line.
  - The same with three moves back and five forward (`…,backward=3,forward=5`). Before:
    `p001w06 …`, "Bookmark", "Paging", then forward through Bookmark and the heading to
    `p001w11 …`. After: back to the heading and forward to `p001w21 …`, every line once.
  - The cursor back on the last control (`touch=Bookmark,forward=2,backward=2,listen=22,screenshot,forward=4`).
    Before: "Chapter one Heading", "Bookmark", "Chapter one Heading", `p001w01 …`. After:
    the heading and three lines in order.
  - The rotor's choice on a line (`touch=p001w01,flick=down,listen=22,screenshot,flick=down,forward=2`,
    dark at 20 seconds). Before: "Next Page", and after the change "Previous Page" at the
    second flick, the rotor where it was, then `p002w05 …` and `p002w01 …`, lines from
    further down the page and out of order: the log has `Found element: p001w06 …` taken
    as it was and `Will set element: p002w05 …`. After: "Next Page" again at the second
    flick, then `p001w06 …` and `p001w11 …`. The rotor is at its default again, because
    VoiceOver set its cursor on the line's new item at the forced update: the cost of the
    change there is one flick down. The entry after this one is where it keeps its place.
  - The iPad, the cursor in a table's cell
    (`OPS/grids.xhtml`, `touch=Twelve metres,backward=2,forward=2,listen=22,screenshot,backward=1,forward=3`).
    Before the change the moves read "Opened 1901 Column 2", "Station Alder Row header
    Column 1", and forward again to "Depth Twelve metres Column 3". After it, before:
    "1901", a cell without its header or its column, then "Alder Depth Twelve metres Row 2
    Column 3" as of a table newly come into, with `currentValid=0` between. After: "Opened
    1901 Column 2", "Depth Twelve metres Column 3", "Station Birch Row header Row 3 Column
    1", "Opened 1934 Column 2".

  A cursor whose page is turned, which is sent to the page shown.
  - On a line (`touch=p001w01,listen=25,screenshot,forward=3,backward=4`, the turn at 25
    seconds). Before and after alike: `p002w19 …` heard at the turn, three lines on, and
    back through it to "Bookmark". Each log has one layout change at the turn, naming an
    element.
  - The rotor's choice
    (`touch=p001w01,flick=down,doubletap=Next Page,listen=4,screenshot,flick=down,forward=3`).
    Before and after alike: "Next Page", `p002w19 …` heard by itself, "Previous Page" at
    the second flick, and three lines in order.
  - The iPad, with a table under the cursor: the sessions recorded for the rotor's place.
    From a cell to a line, in `OPS/grids.xhtml`
    (`touch=Twelve metres,flick=down,doubletap=Next Page,listen=4,screenshot,flick=down,forward=3`):
    "Line 06 after the grids." by itself, "Previous Page", and "Line 07 …" to "Line 09 …".
    From a line to a cell (`OPS/ledger.xhtml`, from the heading, with `backward=3`): "Entry
    28 Row 29 Column 1 Table start 41 rows 3 columns", "Previous Page", and the cells each
    way. And back out by `doubletap=Previous Page`: "A table longer than a page Heading",
    "Previous Page", "Words before the ledger." and the table's first cell. Before and
    after alike in each.
  - The lane's default steps on the first book, on both simulators: the two transcripts
    are the same line for line, 54 lines on the iPhone and 110 on the iPad.

  One thing was tried on a build that is not in the branch: a second layout change with no
  element right beside the one that sends the cursor, before it or after it, as the page
  shown again for a new size just before a turn would post. Ten sessions of the four
  cases above with a cursor on a line or a cell. Nine read as before, the line or cell by
  itself and "Previous Page" at the flick. In the tenth, from a cell to a line with the
  extra change first, on a simulator booted for it, nothing was heard in the four seconds
  after the turn and the line was standing at the flick; two repeats read as before.

  Not established: a device, and a key on a hardware keyboard, for which the sample's own
  turn stands. A move made sooner than 0.8 s after the page is shown, which VoiceOver's
  log says it does not follow with a forced update. VoiceOver's three-finger scroll is as
  it was, announced and with no layout change when its cursor has not left the page;
  XCTest cannot make the gesture.
- The rotor's place when the same page is shown again under VoiceOver's cursor, which the
  entry above left at its default
  ([#516](https://github.com/vocaro/EPUBLib/issues/516);
  [the rotor keeps its place only on the same element object](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#the-rotor-keeps-its-place-only-on-the-same-element-object)):
  on 2026-10-13, after that change
  had merged. Simulators
  of the session's own on iOS 27.0 with Xcode 27.0, at 17 points: two iPhone 17 Pros (402 ×
  874) with the book of ordinary paragraphs and the first book, and an iPad Air 13-inch
  (M4) with the first book, upright (1024 × 1366) but where it says otherwise. Through
  XCTest's VoiceOver service, VoiceOver switched on for each session and read back as off
  after it; nobody listened, and no device has run it. "Before" is main at `888fd7b` and
  "after" is `6dae9ee`. Each step list was a session of its own on each, fifty-six in
  all, at load averages from 6 to 79, and each ran all its steps and ended with
  xcodebuild's status 0. The sample makes the reader dark by itself (`-SampleDarkAfter`).
  VoiceOver's own log is quoted ([Simulators](#simulators)).

  The cursor on a line, with an action chosen in the rotor.
  - `touch=p001w01,flick=down,listen=22,screenshot,flick=down,forward=2`, dark at 20
    seconds. Before: "Next Page", nothing during the `listen`, "Next Page" again at the
    second flick, then `p001w06 …` and `p001w11 …`. The log has `Received note: Layout
    Changed` with no element at 12:08:44.784, and at 12:08:45.592 `Proposing current
    element` and `Will set element`, both for `p001w01 …`, then `Forced update, so
    removing all from cache` and `fetch count: 2`. After: "Next Page", nothing during the
    `listen`, "Previous Page" at the second flick, and the same two lines. The log has the
    change at 12:09:44.632, and at 12:09:45.400 `Proposing current element`, the forced
    update and the fetch, with no `Will set element`. In neither did VoiceOver begin to
    speak between the change and the screenshot, which shows the page dark and the cursor
    on its first line.
  - The rotor stepped both ways afterwards
    (`touch=p001w11,flick=down,flick=down,listen=22,screenshot,flick=down,flick=up,backward=2,forward=4`,
    dark at 24 seconds). Before: "Next Page" and "Previous Page", and after the change
    "Next Page" and "Activate Default": the rotor had started anew. After: "Next Page" and
    "Previous Page", then "Activate Default", which follows Previous Page, and "Previous
    Page" at the flick up. The moves read the same in both: `p001w06 …`, `p001w01 …`, and
    forward through `p001w11 …`, the line the cursor had been on, to `p001w21 …`.
  - A heading, a link and a picture under the cursor (the first book, dark at 18 seconds,
    each after one move away and back, as
    `touch=Page boundary,forward=1,backward=1,listen=22,screenshot,forward=1,backward=1,forward=2`).
    Before and after alike, and the item the cursor had been on is read as what it is
    each time VoiceOver comes back to it: "Page boundary verification Heading",
    "Verification link Link", "Blue verification square Image". Before, each log has `Will
    set element` at the forced update. After, none has.
  - The iPad on its side with the book of paragraphs, the cursor in the right-hand page
    (`rotate=landscape,touch=p005w08,flick=down,listen=22,screenshot,flick=down,backward=1,forward=2,rotate=portrait,visible`,
    dark at 24 seconds). Before: "Next Page" again at the second flick. After: "Previous
    Page". `p005w01 …`, `p005w08 …` and `p005w15 …` follow in both.

  The cursor in a data table's cell (the iPad, `OPS/grids.xhtml`).
  - With an action chosen
    (`touch=Twelve metres,flick=down,listen=22,screenshot,flick=down,backward=1,forward=3`,
    dark at 20 seconds). Before: "Next Page" again at the second flick. After: "Previous
    Page". Then in both "Opened 1901 Column 2", "Depth Twelve metres Column 3", "Station
    Birch Row header Row 3 Column 1" and "Opened 1934 Column 2".
  - The entry above's session
    (`touch=Twelve metres,backward=2,forward=2,listen=22,screenshot,backward=1,forward=3`),
    and the same with the move forward made first
    (`…,screenshot,forward=1,backward=1,backward=2`). The first reads those four cells in
    both, and the second "Station Birch Row header Row 3 Column 1", "Alder Depth Twelve
    metres Row 2 Column 3", "Opened 1901 Column 2" and "Station Alder Row header Column
    1". Before, the first move after the change is followed by VoiceOver's hint about the
    rotor, as a move after a touch is. After, it is not.
  - The same three with the iPad on its side, where the table is in the left-hand page:
    as upright in both, and "Previous Page" at the second flick after. They were not
    meant to be: an earlier session had left the simulator turned.
  - With the cell's item kept and a new item for its table, on a build that is not in the
    branch: "Previous Page" at the second flick, the rotor kept, and the cell the cursor
    had been on read with its header cells and without its place at every return to it,
    "Depth Twelve metres" for "Depth Twelve metres Column 3" in two sessions and "Alder
    Depth Twelve metres" for "Alder Depth Twelve metres Row 2 Column 3" in a third. The
    cells round it were read as before, and VoiceOver's log of those moves is the same
    item for item as with a new cell: it does not say why the place is left out. With
    the table's item kept as well, which is the change, the place is said.

  The sessions of the entry above read as they do there, before and after alike. On the
  iPhone: a page turned with the cursor back on the last control, on the page button with
  the whole page held (the menu closed, and a chapter chosen), with two lines or the whole
  page held and not visited, and by the page button touched twice; the page shown again
  with the cursor on its third line, near and far, and back on the last control; the
  cursor on a line whose page is turned, with and without the rotor's choice. On the iPad:
  from a cell to a line, from a line to a cell, and back out by Previous Page. And the
  lane's default steps on the first book, on both.

  Not established: a device, where that a double tap then performs the action chosen is
  still to be shown. A move made sooner than 0.8 s after the page is shown, as in the
  entry above. A page shown again with its lines broken differently, as after a change of
  text size: the cursor's line is then no line of the page, and the cursor is sent to the
  page as after a turn.
- The two lines that used to be listed each side were one short when VoiceOver moved back up
  the screen, menu or no menu. Three lines above the cursor must be listed
  ([VoiceOver moves through a cache of the items around its cursor](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-moves-through-a-cache-of-the-items-around-its-cursor)),
  and two were unless more of the screen lay above the cursor. UIKit scrolls the line the
  cursor is going to into view before VoiceOver asks, which lists two more, so the answer was
  usually right. On 2026-10-12 another session saw VoiceOver leave the text for Bookmark at
  "Line 02 after the table." or "Line 01" in two of three simulator sessions on main
  (`TEST_RUNNER_VOICEOVER_HREF=OPS/table.xhtml`, `touch=Bookmark,forward=16,backward=16`,
  with a second table added to the section, as #382 does), and one of ten did here. In the
  six of those that were logged, the line VoiceOver asked from was the first line listed
  until the view had scrolled, and the list was made again only as the question arrived.
  With fifty lines listed, four sessions of the same steps read back to the heading, and
  the list began fifty lines above that line before the scroll as after it. Two more sessions gave no transcript: VoiceOver's automation
  failed at the third move in one and the reader did not start in the other, at load
  averages of 800 to 1,000.
- `xcodebuild`'s console output lost three of one device run's 160 `VOICEOVER_EVENT` lines,
  three moves back in a row, which the transcript attached to the result bundle had
  ([results and restoration](https://github.com/vocaro/apple-engineering/blob/main/guides/simulator-testing.md#results-and-restoration)).
- In the simulator, UIKit scrolled the line VoiceOver's cursor came to as
  [UIKit's own text view elements are every paragraph](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikits-own-text-view-elements-are-every-paragraph)
  describes. A line that was the first listed when
  VoiceOver took it led back to the control before the text on the next move back, though
  lines had been listed before it since: it had asked for the two items before that line as
  it landed. When the list shrank to the screen between the two halves of a move, VoiceOver
  stopped at a line it had reached above the screen.
- Not done on a device: a larger text size, VoiceOver's three-finger scroll and its read-all
  gesture, which XCTest cannot make
  ([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)),
  a book whose lines hold floats or tables, and listening.
- On 2026-10-12 the hidden-labels section was read on a physical iPhone 17 Pro Max and a
  physical iPad Air 13-inch (M3), both on OS 27.2, through XCTest's VoiceOver service and not
  by ear. At 17 points, moving forward from the Bookmark control, in pages and in continuous
  scroll with its lines listed: "Parked title heading", "By the parked author.", "Book Image",
  "Shown opening words.", "Clipped words in the line.", "Shown closing words.", "Parked link
  to the target Link", "Shown last words.". In continuous scroll the lines on screen above
  the section came first, ending "Link target reached" and "This is the end of the numbered
  paragraph.", and moving back gave the same items in reverse. Pages were read at 28 points
  too, and on the iPad in landscape with two columns: on the iPhone the line wraps at that
  size, and the clipped words came between "Shown opening words." and "Shown". Before the
  scroll view listed its lines, continuous scroll read a paragraph at a time, at 17 and 28
  points, with each label in the paragraph it stands in: "￼ Parked title heading ￼ By the
  parked author. ￼", "Shown opening words. ￼ Clipped words in the line. Shown closing words.",
  "￼ Parked link to the target Shown last words. Double tap to activate embedded link".
  Neither label hidden from everyone was read in any run, the screenshots show the image and
  the shown words only, and VoiceOver was off on both devices afterward. On the iPad the
  probe needs `touch=Bookmark` before `read`: from the first item its cursor stayed on the
  window's resize control in a simulator. The iPad refused UI automation twice that day
  ("Timed out while enabling automation mode") and ran half an hour later with nothing
  changed from the Mac
  ([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).
- The same day, on both devices, the section with a hidden heading over a table, at 17
  points. Opened in continuous scroll, the first move forward from Bookmark gave "Parked
  table heading", then "First cell Second cell Image", "Third cell Fourth cell Image",
  "Shown words after the table." and the lines after it, and moving back returned through
  the rows to "Parked table heading". The screenshots before and after are the same but for
  VoiceOver's cursor, a point above the table: the view did not move. In pages the table's
  four cells came first, each an item, then "Parked table heading", then the rows: a
  table's cells are read before the lines of their page there, whatever those are. That is
  since changed; see the entry on a table's rows below.
- The same day the section was heard on a Mac: GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in three
  [hosted sessions](#hosted-mac-sessions) at `d010812`, in a window 600 points wide at 17
  points. The section was then the book's last: fourteen `ax:next` steps reached its page
  (twelve turn pages), and in continuous scroll `textend` put VoiceOver on "Link target
  reached", three lines above it. In pages, on entering: "In text Parked title heading By the parked author. Book
  image im", the 64 characters the probe records. By line: "Parked title heading By the
  parked author. Book image image", "Shown opening words. Clipped words in the line. Shown
  closing w", "Parked link to the target Shown last words.", "end of text". By word each
  label is one stop: "Parked title heading", "By the parked author.", "Book image image",
  "Shown", "opening", "words.", "Clipped words in the line.", "Shown", "closing", "words.",
  "Parked link to the target", "Shown", "last", "words.". In continuous scroll the lines
  after "This is the end of the numbered paragraph." were the same three, and Read All gave
  them in order, a sentence at a time. Neither label hidden from everyone is in any
  transcript. A fourth session, at `1e44a71`, read the page that opens with a hidden heading
  over a table (thirteen `ax:next` steps): on entering, "In text Parked table heading"; by
  line, "Parked table heading", "Table row group", "Shown words after the table."; by word,
  "Parked table heading", "Table row group", "Shown", "words". Nobody listened, and no
  workstation was used.

- The same day a book's headings were heard on a Mac
  ([Mac headings need a rotor, rich-text levels and child elements](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#mac-headings-need-a-rotor-rich-text-levels-and-child-elements)):
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in four
  [hosted sessions](#hosted-mac-sessions) at `41a458f`, in a window 600 points wide at 17
  points, at the fixed pause. In continuous scroll `rotor` opened on "Page boundary
  verification, heading level 1" and `listdown` went on through "Link target reached, heading
  level 2", "Parked title heading, heading level 1", "Parked table heading, heading level 1"
  and "Pictures and their words, heading level 1". `listchoose` on the fourth moved VoiceOver
  to "Parked table heading", which `line` read back. `nextheading` from the first paragraph
  gave "Link target reached", then "Parked title heading", "Parked table heading", "Pictures
  and their words" and "Heading not found". At `8baffa1`, with the book a section shorter,
  the observer's `STATE` after the first of those moves had the insertion point on the
  heading and the heading's line the first on screen, and the moves were the same from the
  text area without interacting. In pages the first page's rotor opened on "Page boundary
  verification, heading level 1" and `nextheading` from that heading gave "Heading not
  found", the page holding no other; the page that opens with a hidden heading over a table
  (thirteen `ax:next` steps) listed "Parked table heading, heading level 1" alone, and
  `listchoose` moved to it. VoiceOver read a heading's words on moving to it and by line,
  and said its level nowhere but in the rotor's list. At `53a7cbe`, before the list began
  with the first heading, the page whose only heading was its first line gave "No items in
  Heading menu" and the scroll view's list lacked the heading that opens the book.
  Control-Option-Command-Shift-H moved to the next heading, not the one before
  ([key commands](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#key-commands)).
  Not heard:
  two columns, a larger text size, a move back by a VoiceOver command, and the hidden-labels
  page in pages, whose session ended twice in the runner script's check of VoiceOver's state
  with no transcript written: the rotor was still open, as the pitfall above describes.
  Nobody listened, and no workstation was used.
- The same day a move by heading was heard to go through the whole book in pages on a Mac:
  the hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0),
  in six [hosted sessions](#hosted-mac-sessions) at `08cd4a7`, at the fixed pause, in a
  window 600 points wide at 17 points, which is one column, and 1100 wide at 23, which is
  two. From the first page `rotor` opened on "Page boundary verification, heading level 1"
  and `listdown` went on through "Link target reached, heading level 2", "Parked title
  heading, heading level 1", "Parked table heading, heading level 1", "Pictures and their
  words, heading level 1" and "Scenes set apart, heading level 1": the whole book's, with
  the first page still on screen. `listchoose` on the last turned to its page, where `line`
  read "Scenes set apart". The rotor opened there on the book's first heading again, and
  `listchoose` turned back to the first page. From the first page's heading `nextheading`
  turned to the page of `word1187` to `word1200`, where `line` read "Link target reached"
  and `STATE` had the insertion point on that line; then to the pages of "Parked title
  heading", "Parked table heading", "Pictures and their words" and "Scenes set apart"; and
  then gave "Heading not found". At each turn VoiceOver read the new page from its top, as
  after any page turn ("text word1187 word1188", "text Parked table heading" and "Table row
  group"), and `line` read the heading. From the page of `word0286` to `word0395`, with
  VoiceOver's cursor resting on the column, three `nextheading` steps went to "Link target
  reached", "Parked title heading" and "Parked table heading". In two columns `nextheading`
  from the left column went through the same five to "Heading not found"; with VoiceOver in
  the right column the rotor listed the same six, and `listchoose` on the last turned to
  its page and put VoiceOver in the left column, on the heading; and from the right column
  of the spread of `word0229` to `word0364`, at rest, `nextheading` went to "Link target
  reached" and then "Parked title heading". Two more sessions, at `36573a5` in two columns
  at 21 points, met "Link target reached" where it opens its page: `nextheading` from the
  first page, and `listchoose` on it with VoiceOver in the right column, each gave "text
  Link target reached" and then "This is the end of the numbered paragraph.", the heading's
  words first. Every heading was in the left column of the spread turned to, at 17, 21 and
  23 points. Four earlier runs, on a throwaway branch that wrote each of the rotor's
  queries to a file, found how VoiceOver asks ([native viewer](native-viewer.md#input-and-accessibility),
  Headings). It loaded a heading given as a token only on moving to it, the element and
  then the range, and never while it listed the rotor's items. At `6e2c1f0`, and on that
  branch with the same code, a token's result had no range: the list showed all six labels
  and VoiceOver read each row of another page out as the column's own text, "text Page
  boundary verification" from the first page and "text word0076 word0077" from a right
  column. There too the search took a cursor resting on a column for nowhere, and
  `nextheading` from the page of `word0286` went back to the first page. Leaving out the
  reader's layout-change notice for the page turned to, or putting the insertion point on
  the heading before posting it, did not change what VoiceOver read on arriving. At
  `c3313e2`, with the link elements of #412 merged, a session in one column repeated the
  list, a choice from it and two moves, with the same result. With VoiceOver's cursor on a
  link, reached by `nextlink`, `nextheading` said "Heading not found" there, and so did
  main at `150698b` in continuous scroll, where the same step from the text gave "Link
  target reached": a link's element has no rotor
  ([#431](https://github.com/vocaro/EPUBLib/issues/431)). Not heard: a heading that lands
  in the right column of a spread, a book still being built, a section that page turns
  step over, words typed in the rotor's list, and a move back by a VoiceOver command.
  Nobody listened, and no workstation was used.
- On 2026-10-13 a move by heading from a link was heard on a Mac
  ([#431](https://github.com/vocaro/EPUBLib/issues/431)): the hosted `xcode-27` runner
  (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points wide
  at 17 points, at the fixed pause. Before, `ax:focus in nextlink nextheading` gave
  "Verification link hyperlink" and "Heading not found", on main at `150698b` in continuous
  scroll (run 38348707110) and at `c3313e2` in pages (run 38348132407).
  At `9520fa2`, with each heading an element among the text's children, in continuous
  scroll (run 38358638705). `ax:links` gave three children: the heading "Page boundary
  verification", the link, and the heading "Link target reached", the next one below the
  screen. `nextlink nextheading` gave "Verification link hyperlink" and "heading level 2
  Link target reached", then "word1151": VoiceOver had scrolled, the reader had put the
  insertion point on the first line on screen, which begins `word1152`, and VoiceOver says
  the word before it. `describe` gave "Link target reached heading level 2 is in the
  VoiceOver cursor", and `right` and `line` read "word1152" and its line. Two more
  `nextheading` steps went on to "heading level 1 Parked title heading" and "heading level
  1 Parked table heading". With the reader opened at the pictures, three `nextlink` steps
  and `nextheading` gave "Described jump, image hyperlink" and "heading level 1 Scenes set
  apart"; opened at the hidden labels, "Parked link to the target hyperlink" and "heading
  level 1 Parked table heading". From the text `nextheading` still said the words alone,
  "Link target reached" and "Parked title heading", and the pictures read by line as
  before, with `nextlink` after them "image hyperlink".
  In pages (run 38359816674) the first page's children were its heading and its link, and
  `nextlink nextheading` gave "heading level 1 Page boundary verification": the page's
  only heading, which stands before the link. On the pictures' first page the same steps
  gave "image hyperlink" and "heading level 1 Pictures and their words"; `right` then gave
  "Pictures", back in the text, and `nextheading` turned to the page of "Scenes set
  apart", which `line` read. From the text `nextheading` turned to the page of `word1187`
  as before, and `line` read "Link target reached".
  `rotor` from a link (run 38360731125): in continuous scroll "Heading menu", "On item
  Page boundary verification, heading level 1", `listdown` twice "Link target reached,
  heading level 2" and "Parked title heading, heading level 1", and `listchoose` moved
  there, where `line` read "Parked title heading By the parked author."; in pages the list
  opened on the same row, five `listdown` steps named the rest of the book's headings to
  "Scenes set apart, heading level 1", and `listchoose` turned to its page, where `line`
  read "Scenes set apart". Main gives that list from a link too: VoiceOver asks the text
  for its rotors as well as the link. VoiceOver opens the rotor on the menu it showed
  last: two other sessions, each after one that had gone on to Window Spots with
  `listright`, opened there. At `1d5b131` (run 38362891089) the first move was the same
  in each flow, and `ax:follow=Parked` on the hidden-labels page, whose first child is now
  the heading "Parked title heading", pressed the link: the observer passes over a
  heading when it looks for a link by its words.
  Four earlier runs, on a throwaway branch that wrote what VoiceOver asked to a file,
  found how the move goes ([native viewer](native-viewer.md#input-and-accessibility),
  Headings). With the text's rotors given to a link's element in three ways, the move
  still said "Heading not found" and asked for no rotor (run 38352084124); the rotor's
  list asked the link's element for them. From the text VoiceOver asked the text area for
  its rotors, searched from the range of its cursor's line and set the selected range to
  the heading; from a link it asked the link for the names of its parameterized
  attributes, then the text area for its children, and read each child's subrole and title
  (run 38353914086). With a heading element for every heading of the book among the
  children, the move went to the next one after the link. The view scrolled from
  `-[NSScroller accessibilitySetValueAttribute:]`: VoiceOver sets the scroll bar's value
  (run 38355673448). With a link's element offering `AXUIElementsForSearchPredicate` and
  answering for headings alone, Find Next Link asked it for the next link and said "Link
  not found" (run 38357037596; [#454](https://github.com/vocaro/EPUBLib/issues/454)).
  In pages on that branch, where a column's rotor still held its page alone and the search
  stood at the link, the rotor's list from the first page's link said "Heading menu" and
  no row, and `listchoose` chose nothing: the search had answered the question VoiceOver
  asks from the link's element with no item. That was heard once.
  Not heard: a heading that follows a link on the same page in pages, which the book has
  none of and the unit tests read; a link after the book's last heading; two columns; a
  larger text size; a link in a table cell, which is the cell's own text view's; and
  listening. Nobody listened, and no workstation was used.
- On 2026-10-13 the move by heading from a link was heard to reach a later page, and reading
  on to start at the heading ([#454](https://github.com/vocaro/EPUBLib/issues/454)): the
  hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), at
  the fixed pause, in a window 600 points wide at 17 points unless said. Nobody listened.
  The reader's code is the same at `040d7d1` and at `d634854`.
  In pages (runs 38385462515 at `040d7d1` and 38388657406 at `d634854`). `ax:links` on the
  first page gave three children, the heading "Page boundary verification", the link, and
  the heading "Link target reached", which is on the page of `word1187`, each heading
  `FOCUSABLE`. `ax:focus=search ax:focus=0 in nextlink nextheading` gave "Verification link
  hyperlink" and then, with `AXLayoutChanged` and that page as the column's value, "heading
  level 2 Link target reached", "Page boundary verification" and the heading again, or the
  last two alone; `describe` "Link target reached heading level 2 is in the VoiceOver
  cursor"; `line` "Link target reached"; `right` "Link"; and `nextheading` from there, by
  the rotor, the page of "Parked title heading", which `line` read. From element to
  element, `nextlink` and three `nextheading` steps gave "heading level 2 Link target
  reached", "heading level 1 Parked title heading" and "heading level 1 Parked table
  heading", a page turned for each, with `describe` naming each and `line` reading "Parked
  title heading By the parked author." and "Parked table heading". Opened at
  `OPS/offers.xhtml`, the page's children were its heading, "Lone jump", "Right cell jump"
  and the heading "Tables of data", three sections on, and `nextlink nextheading` turned
  to it. Opened at `OPS/grids.xhtml`: "Reopened 1978 hyperlink", a cell's link the page
  lists, then "heading level 1 A table longer than a page", "heading level 1 A row taller
  than a page", and from that one, the book's last, "Last heading heading level 1 A row
  taller than a page".
  In continuous scroll, the same two runs. `nextlink nextheading` gave "word1200", the
  word before the heading, and "heading level 2 Link target reached"; `describe` named the
  heading; `right` said "Link" and `line` "Link target reached"; `nextheading` went on to
  "Parked title heading". With the insertion point before "Words before the stations"
  (`ax:caret`), `nextlink` and three `nextheading` steps gave "Reopened 1978 hyperlink",
  the two headings after it and "Last heading heading level 1 A row taller than a page".
  From the first link of the pictures two `nextheading` steps reached "What each line
  offers", and `right` said "What" (run 38385503705).
  Two columns, a window 1100 points wide. At 17 points the turn put "Link target reached"
  in the left-hand column and the phrases were those of one column, `line` "Link target
  reached" and `right` "Link". At 20 points it was in the right-hand column (`ax:lines`:
  `word1048` to `word1147` on the left, `word1148` to `word1200` and the heading on the
  right, the insertion point on the heading): "heading level 2 Link target reached",
  "ord1105 word1106 word1107", "2 updated items"; `describe` named the heading; `line` read
  "word1048 word1049 word1050 word1051 word1052", the left-hand column's first line, and
  `right` "word1048"; `nextheading` from there said "Link target reached", by the rotor,
  and `line` read it. From the heading's element in the right-hand column `nextheading`
  turned to "heading level 1 Parked title heading", on a spread of one page: `describe`
  named it and `line` said nothing. With the keyboard focus given to the column that shows
  the heading (run 38387134530, at `26b23f8`, taken out again): after the heading
  VoiceOver said "text word1148 word1149 word1150", `describe` "text is in the VoiceOver
  cursor Line 12", `line` "Link target reached", and `right` "VoiceOver Page Boundary
  Verification", outside the text.
  With cursor tracking off (`tracking`, "Cursor Tracking Off"; run 38385462515), in pages:
  `nextlink nextheading` said "heading level 2 Link target reached" and the page stayed;
  `describe` named the heading, `line` read "Page boundary verification" and `right`
  "Page"; `nextheading` from there turned to the page of `word1187` by the rotor.
  The links with the change in place, at `040d7d1` (run 38385503705). In
  pages: "Verification link hyperlink", "Last link Verification link hyperlink", and
  `activate` the page of `word1187`, the same again at `d634854`; on the pictures "image hyperlink", "Jump with
  decoration hyperlink", "Described jump, image hyperlink" and "image hyperlink" again,
  `ax:links` there listing the heading, the three links with `AXPress` and the heading
  "Scenes set apart"; on the hidden labels "Parked link to the target hyperlink" and
  `activate` its target. In continuous scroll the pictures' links the same four phrases.
  From the text `nextheading` went by the rotor as before, and `rotor` from a link and
  from a heading's element opened on "Page boundary verification, heading level 1".
  `lastword line nextline right right` on the first page read its last line, "end of
  text" and nothing more: the heading at the column's foot is no part of the text.
  Before the heading's element said whether it has the focus, at `4338642` (run
  38383603629), VoiceOver said the heading on the later page and the page stayed, with
  cursor tracking on: it had not focused the element.
  With main merged in at `a41e642`, where the scroll view tells of its insertion point a
  second time after a move of the reader's own
  ([#473](https://github.com/vocaro/EPUBLib/pull/473)), five sessions gave the same phrases
  in pages and in continuous scroll, "word1200" and the heading among them, with `describe`
  still naming the heading (run 38415339848).
  Four runs before those, on a throwaway branch that logged every request to the text view
  and answered VoiceOver's search for elements in variants chosen by launch arguments
  (`claude/probe-heading-search-454`, whose code is kept as a patch in
  [#454](https://github.com/vocaro/EPUBLib/issues/454#issuecomment-6155463999); a pause of
  3 seconds), are why the reader offers no
  search ([native viewer](native-viewer.md#input-and-accessibility), Headings;
  [never offer VoiceOver the accessibility element search](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#never-offer-voiceover-the-accessibility-element-search)):
  - Run 38372960899. A link's or a heading's element that offers the search is asked
    `{AXDirection = AXDirectionNext; AXResultsLimit = 1; AXSearchKey = (AXHeadingSearchKey)}`,
    with no start, and each later child after it, then the first ones; from the text every
    child is asked with `AXStartRange`, the text cursor's range. A text area that offers it
    is asked with `AXStartElement` the link's element when no heading among the children
    follows the link, and from the text with `AXStartRange` and then with `AXStartElement`
    the text area. On main Find Next Link from the text takes the first link child wherever
    the text cursor is: with the insertion point after the three links of the pictures it
    said "image hyperlink".
  - Run 38375928821. The text area answering with nothing: "Heading not found" from a
    link, and "Last link Described jump, image hyperlink" from the last link, with no
    beginning again; answered with the first link from the last, VoiceOver said nothing.
    An answer that is no child of the text, a heading two screens down or a link below
    the screen, sent VoiceOver's cursor back into the text without a word.
  - Run 38378273449. A search for links left unanswered: "Link not found" in continuous
    scroll, and in pages the column was asked again and again until the session ended with
    VoiceOver still on. From the last heading's element, answered with nothing, "Last
    heading heading level 1 What each line offers".
  - Run 38380756140, the text area offering the search beside main's reader. On main, from
    the text, `Control-Option-Command-O`, `C` and `P` moved to the next change of font, of
    style and the next plain text ("Link target reached" for the style), and `U` and `K`
    to the underlined link and the next change of colour. With the search offered, the
    first three said "VoiceOver Page Boundary Verification", "VoiceOver Verification" and
    "No bookmark saved Bookmark menu button": VoiceOver had left the text. `G` from there
    asked the text area 3,577 times in 25 seconds, said "Searching
    VoiceOverVerificationMac" and "VoiceOverVerificationMac not responding", and the
    session ended `NOT_RESTORED`; `B` from a page's text asked the column 6,042 times in
    34 seconds, with the same two phrases. With the next link below the screen among the
    children, Find Next Link from "Verification link" said "Parked link to the target
    hyperlink" and the view scrolled to it
    ([#425](https://github.com/vocaro/EPUBLib/issues/425)).
  Not heard: a link after the book's last heading, which the verification book no longer
  has, so the move that begins again there; a heading that follows a link on the same
  page; a larger text size; a workstation; and listening.
- On 2026-10-13 the move by heading from a link was heard to a heading already on the page
  or on screen ([#454](https://github.com/vocaro/EPUBLib/issues/454)), which the two
  entries above list as not heard: the hosted `xcode-27` runner (image `20261006.0244.1`,
  macOS 27.0.1 `26A434`, Xcode 27.0), at the fixed pause, in a window 600 points wide at 17
  points unless said, the reader opened at the fixture's last section
  (`"launch=-SampleHref OPS/parts.xhtml"`), which was added for it. Nobody listened.
  On main's reader, `ed747d8` with the section added (run 38431856142 at `ec871c2`). In
  pages `ax:links` gave the first page four children: "upper jump", the heading "Second
  part opens", "lower jump" and the heading "Third part opens", which is on the next page.
  `ax:focus=search ax:focus=0 in nextlink nextheading` gave "upper jump hyperlink" and
  then, with `AXSelectedTextChanged` at the heading, "heading level 3 Second part opens"
  and 58 ms later "finish.", the word before the heading; `describe` "Second part opens
  heading level 3 is in the VoiceOver cursor", `line` "Second part opens" and `right`
  "Second". In continuous scroll (`ax:focus in nextlink nextheading`) "finish." alone was
  recorded. From "last jump", after the book's last heading, the move began again with the
  first heading on the page or on screen: on the second page (`ax:next` first) "cease."
  alone, where the heading is "Third part opens", and in continuous scroll, three
  `nextlink` steps in, "heading level 3 Second part opens" and 114 ms later "finish.".
  The hint followed each time, "You are currently on a heading level 3, inside of a text
  area" or the same of level 4. In a window 1100 points wide, from "lower jump" in the
  left-hand column to "Third part opens" in the right-hand one, with no page turned,
  `AXSelectedTextChanged` came from the right-hand column and VoiceOver said "heading
  level 4 Third part opens" and no word; `line` read "Parts below a jump", the left-hand
  column's first line, and `right` "Parts"
  ([#482](https://github.com/vocaro/EPUBLib/issues/482)). Opened at the pictures in
  continuous scroll, where "Scenes set apart" is below the screen: "heading level 1 Scenes
  set apart", "pictures." and the heading again, with `AXLayoutChanged`.
  With a heading on the page or on screen left as it is, at `f59de08` (runs 38433616775
  and 38435841497). The same steps gave "heading level 3 Second part opens" and nothing
  more until the hint three seconds later, in pages and in continuous scroll, with no
  `AXSelectedTextChanged`; from "last jump", "heading level 4 Third part opens" on the
  second page and "heading level 3 Second part opens" in continuous scroll. `describe`
  named the heading each time. `line` read "Parts below a jump", and "Middle words cease."
  on the second page, and `right` "Parts" and "Middle": the line VoiceOver had entered the
  text at. From a heading's element to the next (`nextlink nextheading nextheading`), in
  continuous scroll "heading level 3 Second part opens" and "heading level 4 Third part
  opens", both on screen and both whole, and a third `nextheading`, from the book's last
  heading with another on screen, "heading level 3 Second part opens" again. In pages the
  second step turned the page: "heading level 4 Third part opens", "Middle words cease."
  and the heading again, then `line` "Third part opens" and `right` "Third". Two columns
  as on main; the pictures "pictures." and "heading level 1 Scenes set apart", then `line`
  "Scenes set apart". From the text, by the rotor, `nextheading` said "Second part opens",
  which `line` read, and a second one turned to "Third part opens".
  The heading cases of the entries above again at `f59de08` (run 38433623312), with their
  phrases. In pages: "Page boundary verification" and "heading level 2 Link target
  reached" on the page of `word1187`, `describe`, `line` "Link target reached", `right`
  "Link", and from there by the rotor the page of "Parked title heading"; from element to
  element "heading level 1 Parked title heading" and "heading level 1 Parked table
  heading". In continuous scroll: "word1200" and "heading level 2 Link target reached",
  `right` "Link", `line` "Link target reached", and "Parked title heading" by the rotor.
  Opened at `OPS/grids.xhtml` in pages: "Reopened 1978 hyperlink", then a page turned for
  each of "heading level 1 A table longer than a page", "heading level 1 A row taller than
  a page", "heading level 3 Second part opens" and "heading level 4 Third part opens", and
  from that one, now the book's last, "Last heading heading level 4 Third part opens".
  `rotor` from a link opened on "Page boundary verification, heading level 1", and
  `listdown listchoose` turned to "Link target reached", which `line` read. With `tracking`
  first, "heading level 2 Link target reached" and the page stayed. In two columns at 17
  points "heading level 2 Link target reached", `line` "Link target reached" and `right`
  "Link"; at 20 points, with the heading in the right-hand column after the turn,
  "ord1105 word1106 word1107" and "2 updated items" with no heading recorded before
  them, `describe` naming it, and `line` and `right` at `word1048` (run 38433616775).
  Opened at `OPS/grids.xhtml` in continuous scroll the link was not reached: after `in`,
  with `AXSelectedTextChanged` at a line of an earlier section, VoiceOver said "Below",
  `nextlink` said "Link not found", and five `nextheading` steps went by the rotor from
  "Tables of data" to "Third part opens". Main's reader moved the same way after `in` at
  the pictures, to "Line" (run 38431856142).
  One other way was heard, on a throwaway branch (`claude/probe-heading-on-screen-454` at
  `fc425ac`, run 38435847638, the variant chosen by a launch argument; the change is kept as
  a patch in [#482](https://github.com/vocaro/EPUBLib/issues/482#issuecomment-6155464728)):
  the insertion
  point moved to a heading on the page or on screen, as on main, and then a layout change
  that names the text. Posted by the window, as after a scroll: "heading level 3 Second
  part opens", "finish." and the heading again, in pages and in continuous scroll, with
  `line` "Second part opens" and `right` "Second"; from heading to heading "cease."
  between two sayings of "heading level 4 Third part opens". Posted by the element that
  holds the text, as after a page turn: "finish." and the heading in pages, and "finish."
  alone in continuous scroll. Posted by the window it keeps reading on at the heading and
  puts a word before every heading moved to
  ([native viewer](native-viewer.md#input-and-accessibility), Headings).
  With main merged in at `f79c7ac`, which has the link below the screen of
  [#503](https://github.com/vocaro/EPUBLib/pull/503) (run 38437858538): the same phrases
  at the last section in pages and in continuous scroll, "heading level 3 Second part
  opens" whole and `line` "Parts below a jump", and at the first section, "Page boundary
  verification" and "heading level 2 Link target reached" in pages and "heading level 2
  Link target reached", "word1200" and the heading again in continuous scroll, with
  `line` "Link target reached" and `right` "Link" in both. The section's three links
  follow "Reopened 1978", which was the book's last link. In continuous scroll from the
  top of the book twenty `nextlink` steps named seventeen links: the fourteen as before,
  "Reopened 1978 hyperlink", "Birch, 1934 table" and "hyperlink Reopened 1978" for the
  fourteenth, then "an" and "hyperlink upper jump" with `AXLayoutChanged`, "lower jump
  hyperlink" and "last jump hyperlink", and then the same three again, where "Last link
  Reopened 1978 hyperlink" was said before.
  Not heard: a heading only part of which is on screen; a larger text size; a workstation;
  and listening.
- To see what VoiceOver asks of the reader, have the reader write it to a file on a throwaway
  branch, as
  [probing what VoiceOver asks the app](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#probing-what-voiceover-asks-the-app)
  describes; a variant of the reader is given to a session as `"launch=-Name value"`.
- The same day they were read on a physical iPad Air 13-inch (M3) (iPadOS 27.2), upright at
  17 points, at `41a458f`, through XCTest's VoiceOver service; nobody listened. In pages a
  touch on the first page's heading gave "Page boundary verification Heading Use the rotor to
  access Headings", and one turn of the rotor gave "Headings". Each `flick=down` then moved on
  through the book: "Link target reached Heading", with the page of `word1013` to `word1200`
  on screen, "Parked title heading Heading", "Parked table heading Heading", on the page
  that opens with the table, "Pictures and their words Heading" and "Heading not found".
  `flick=up` went back through the same four to "Page boundary verification Heading", the
  first page on screen again, and then gave "Heading not found". In continuous scroll, in
  the book of ordinary paragraphs: "Chapter one Heading Use the rotor to access Headings",
  then "Chapter two Heading" with `p040w28` to `p048w40` on screen, "Chapter three Heading"
  with `p079w29` to `p086w40`, and "Heading not found"; back to "Chapter two Heading"; two
  moves forward into the chapter's lines, the rotor turned to Headings again, and from a
  line that is no heading "Chapter two Heading", "Chapter one Heading" and "Heading not
  found". VoiceOver said a level nowhere. At `64a012b`, where the search looked among the
  lines listed, the move on from "Parked title heading" gave "Heading not found" on this
  iPad and on both simulators: VoiceOver asked the rotor twice for the one move, and the
  second answer, from the same item on a page no longer shown, was not the first
  ([a custom heading rotor must give the same answer twice](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#a-custom-heading-rotor-must-give-the-same-answer-twice)).
- On a physical iPhone 17 Pro Max (iOS 27.2), the same day and commit, a touch on the heading
  gave "Page boundary verification Heading Actions available Use the rotor to access
  Headings" in pages. XCTest's two-finger turn did not move VoiceOver's rotor there in thirty
  turns of several sizes, nor made on the window or on the text, so no move by heading was
  made on the phone: with the rotor still on Actions `flick=down` gave "Next Page". One run
  ended in an exception XCTest raised for a gesture, without the probe's `defer`, and left
  VoiceOver on: it was switched off with `devicectl device settings voiceover --disable`
  and read back as off, and the probe now restores VoiceOver from a teardown block
  ([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).
- The [simulator lane](#simulators) read them the same day at `8c19f15`, on an iPhone 17 Pro
  and an iPad Air 13-inch (M4) (iOS 27.0), when the book had no section of pictures. In
  pages at 17 points both gave "Page boundary verification Heading Actions available Use the
  rot", then with the rotor on Headings "Link target reached Heading" (`word1177` to
  `word1200` on the iPhone's page, `word1040` to `word1200` on the iPad's), "Parked title
  heading Heading" and "Parked table heading Heading", and back through them to "Page
  boundary verification Heading" and "Heading not found". On the iPhone the move to the page
  that opens with the table left VoiceOver on "Open EPUB… Button", and the next
  `flick=down` gave "Parked table heading Heading". In continuous scroll both gave "Chapter
  two Heading", "Chapter three Heading", "Heading not found" and "Chapter two Heading"
  again, with the screens the iPad showed, and from a line of the chapter "Chapter two
  Heading". At 28 points the heading takes the whole of the iPhone's first page: one move
  forward from it gave "Read the numbered words Actions available" and one back "Page
  boundary verification Heading Actions available", so its lines are one item. At
  `9b155ec`, with a heading's label ending in its paragraph's break and no rotor of the
  reader's, the same touch recorded "Page boundary verification" alone, and VoiceOver's
  own rotor gave "Heading not found" past the last heading on screen.
- Not done for headings: listening, a move by heading on an iPhone, landscape and two
  columns, and a larger text size on a device.
- On 2026-10-12 the [simulator lane](#simulators) (Xcode 27.0, iOS 27.0) recorded, at 17
  points: on an iPhone 17 Pro word0001–word0016 in 4 lines and, after Next Page,
  word0017–word0080 in 16; on an iPad Air 13-inch (M4) in portrait word0001–word0301 in 36
  lines, then word0302–word0670 in 45 and word0671–word1037 in 44, and in landscape
  word0358–word0567 beside word0568–word0777, 60 lines read left column first. At 23 points
  the iPad showed word0001–word0146 in 24 lines and then word0147–word0345 in 33; the iPhone
  no numbered line on its first page and word0001–word0036 in 12 on its second. VoiceOver
  spoke every numbered line once and in order, then the book title, where it stayed, and
  XCTest's view of the columns agreed. A phrase is cut at 64 characters, so an iPad line
  shows its first seven words. No page action, rotor action or landscape turn was performed
  by VoiceOver there; see the section.
- On 2026-10-12 the hidden-labels section and the section of pictures were read at 17 points
  after an image with an empty `alt` was left out of what VoiceOver is given and an image with
  no `alt` lost its made-up name. Nobody listened, no workstation was used and no physical
  device: the iPhone and iPad here are the [simulator lane](#simulators)'s, which establishes
  what VoiceOver reads and not that it can activate anything.
  On an iPhone 17 Pro and an iPad Air 13-inch (M4) simulator (iOS 27.0, Xcode 27.0), moving
  forward from the Bookmark control. Hidden labels, in pages and in continuous scroll, at
  `1213dd0`: "Parked title heading", "By the parked author.", "Shown opening words.", "Clipped
  words in the line.", "Shown closing words.", "Parked link to the target Link", "Shown last
  words."; the "Book Image" that came after the author is gone. Pictures, in pages (the iPad
  at `0819ce1`; the iPhone, whose first page ends at "Described jump", at `1213dd0` with Next
  Page between its two pages) and in continuous scroll at `1213dd0`: "Pictures and their
  words", "Undescribed picture", "Image", "stands here.", "Decoration  passed over.", "Bare
  jump:", "Link Image", "Jump with decoration Link", "Described jump Link Image", "Titled
  decoration  passed over.", "Titled picture", "Square with a title of its own Image",
  "stands here.", "Last words about pictures.". "Image" and "Link Image" alone are
  VoiceOver's words for the traits: those elements have no label. In continuous scroll on the
  iPad, read on from the hidden labels, VoiceOver went from the twenty-ninth line after the
  table to the scroll bar, as in [#339](https://github.com/vocaro/EPUBLib/issues/339); the
  pictures were read there with the reader opened at their section.
  On the Mac: GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1
  `26A434`, Xcode 27.0), a window 600 points wide, at `81b9401`, runs 38321044607 (pages) and
  38321046784 (continuous scroll). The labels' page is twelve `ax:next` steps in and the
  pictures' first page twenty; the pictures take two pages there. Hidden labels by line:
  "Parked title heading By the parked author. ", "Shown opening words.  Clipped words in the
  line. Shown closing w", "Parked link to the target Shown last words."; by word: "Parked
  title heading", "By the parked author.", a step with no phrase, "Shown", "opening",
  "words.", "Clipped words in the line.", and on as before. The step with no phrase is
  VoiceOver's cursor crossing the image's character, where "Book image image" was said before.
  Pictures by line: "Pictures and their words", "Undescribed picture  image  stands here.",
  "Decoration   passed over.", "Bare jump:  image ", " Jump with decoration", "Described jump
  image ", "Titled decoration   passed over.", and on their second page (run 38319634156, at
  `55b16e0`) "Titled picture  Square with a title of its own image  stands her", "Last words
  about pictures.", "end of text". By word: "Undescribed", "picture", "image", "stands",
  "here.", "Decoration", a step with no phrase, "passed", "over.", "Bare", "jump:", "image", a
  step with no phrase, "Jump", "with", "decoration", "Described jump image", "Titled",
  "decoration", a step with no phrase, "passed". Continuous scroll gave the same lines, the
  labels' after "This is the end of the numbered paragraph." and the pictures' at the end of
  the book. No transcript has the word "link": on the Mac "Parked link to the target", "Jump
  with decoration" and the linked images are read as text and images. At `55b16e0`, before
  an image without words lost its help text, run 38319737879 heard it as "Undescribed picture
  Double-click or choose Inspect Image to enl": VoiceOver reads the help of an element that
  has no label in the label's place
  ([an element without a name is read by its help or its contents](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#an-element-without-a-name-is-read-by-its-help-or-its-contents)).
  Not heard: VoiceOver activating the link that is an image without a name, which needs a
  device; a note's popover or a table cell with an image in it.
- On 2026-10-12 the section of scenes was read at 17 points before and after a rule was
  given a stop that names it. Nobody listened, no workstation was used and no physical
  device: the iPhone and iPad here are the [simulator lane](#simulators)'s (an iPhone 17 Pro
  and an iPad Air 13-inch (M4), iOS 27.0, Xcode 27.0), which establishes what VoiceOver reads
  and not that it can activate anything. Both sides were recorded on the same `main`
  (`2db7754`).
  Before, at `81f8d88`, moving forward from the Bookmark control, in pages on both: "Scenes
  set apart", "First scene ends.", "  Image", "Second scene starts.", "  Image", "Words
  after an ornament.", then the book's title under the page; on the page that holds a rule
  alone "  Image" and nothing else of the text; on the last "Last words of the scenes.".
  "Image" after two spaces is VoiceOver's word for the image trait of an element that has
  no label, as in the pictures' transcripts. In continuous scroll, where the section is one
  run of lines, the same with a third "  Image" before "Last words of the scenes."; the iPad
  read the lines on screen above the section first, from "Line 57 after the table.".
  After, at `d432df6`: "Separator" in each of those places and "Image" in none, in pages and
  in continuous scroll on both: "Scenes set apart", "First scene ends.", "Separator",
  "Second scene starts.", "Separator", "Words after an ornament."; on the page of a rule
  alone "Separator"; and Next Page from there showed "Last words of the scenes.". The rule
  before "Words after an ornament." has `role="presentation"`, which the reader does not
  read. At `253c79a`, whose reader is that of `d432df6`, in pages on both: from a touch on
  "Second scene starts." three moves back gave "Separator", "First scene ends.", "Scenes set
  apart" and four forward "First scene ends.", "Separator", "Second scene starts.",
  "Separator"; a touch on the rule gave "Separator", and one finger down from there
  "Next Page" and then "Previous Page", the stop's actions; on the page of a rule alone a
  touch on the rule gave "Separator Swipe up or down to select a custom action", and the
  screenshot shows VoiceOver's cursor round the line and nothing else on the page.
  "Actions available" comes and goes along one page as VoiceOver's own rule has it
  ([UIKit offers the actions of every element that contains the item](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikit-offers-the-actions-of-every-element-that-contains-the-item)).
  The continuous-scroll
  transcripts at `81f8d88` and `d432df6` have `-dirty` in their build line: each ran the
  probe as the pages run a few minutes before had built it, at the clean revision, and the
  working tree had been edited since. In continuous scroll VoiceOver went on from the
  section's last line to the scroll bar and then, on the iPad both times and on the iPhone
  before the change, round to the lines above the section and through it again before it
  reached the book's title; moving back from the title it reached the Bookmark control past
  the scroll bar and at most the section's last line. The transcripts before the change
  have both, so neither is the rule's doing. Three further sessions, at load averages near
  1,000, read nothing: two ended with "VoiceOver is on but says nothing" after three
  minutes of silence, and one was not started, because a simulator gave no answer in twenty
  seconds when its volume was set (on such silence, see
  [harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)
  and [honest outcome states](https://github.com/vocaro/apple-engineering/blob/main/guides/evidence.md#honest-outcome-states)).
  Moving back across a rule in continuous scroll was to be read in the last two, and was not.
  On the Mac: GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1
  `26A434`, Xcode 27.0), a window 600 points wide, run 38327683951 at `81f8d88` (pages) and
  runs 38328830423 (pages) and 38328832799 (continuous scroll) at `d432df6`. The scenes'
  first page is 22 `ax:next` steps in, the page of a rule alone 23 and the last 24. The
  section was then the book's last: in
  continuous scroll 28 `ax:next` steps reached the end of the book, where `lastword` put
  VoiceOver on "scenes."; `textend` went to the end of the book's first section instead. The
  reader gives a rule no element there, and both revisions read the same. Pages by line:
  "Scenes set apart", "First scene ends.", a phrase with nothing in it, "Second scene
  starts.", a phrase with nothing in it, "Words after an ornament.": VoiceOver stops on the
  rule's line and says nothing. By word: "Scenes", "set", "apart", "First", "scene",
  "ends.", a step with no phrase, "Second", "scene", "starts.", a step with no phrase,
  "Words", "after", "an", "ornament.", a step with no phrase, "end of text". On the page of
  a rule alone: "In text" and no more on entering, a phrase with nothing in it for the line,
  no phrase for the word or for a move right, and "end of text" for the next line.
  Continuous scroll by line, back from the end: "Last words of the scenes.", a phrase with
  nothing in it, "Words after an ornament.", the same, "Second scene starts.", the same,
  "First scene ends.", "Scenes set apart", "Last words about pictures.". No Mac transcript
  has "Separator" or "image" at a rule.
  Not heard: a physical device; VoiceOver reading on by itself across a rule; a rule in a
  note's popover or in a table cell; a rule that is all a link holds; and what Safari or
  Books says at an `<hr>` on an iPhone, which was not compared.
- On 2026-10-12 the [simulator lane](#simulators) read what VoiceOver offers on a line
  ([UIKit offers the actions of every element that contains the item](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#uikit-offers-the-actions-of-every-element-that-contains-the-item)),
  before and after a line was left with its own actions alone: an iPhone 17 Pro simulator
  (iOS 27.0, Xcode 27.0, 402 × 874) at the launch text size, a touch or a move to the line
  and then `flick=down` to read the rotor. A physical iPad read the change afterwards, as
  told below. Nobody listened.
  Before, at `fc8ed77`. Continuous scroll, the book of paragraphs: "p001w11 p001w12 p001w13
  p001w14 p001w15 Actions available", and the rotor read "Previous Page", "Next Page",
  "Activate Default". Continuous scroll, the first book: "Read the numbered words across two
  consecu Actions available", and the rotor read "Verification link", "￼", "￼", "￼ Jump with
  decoration", "￼", "Inspect Image: Blue verification square", "Previous Page", "Next Page",
  "Activate Default", and the same on "Verification link Link" and on ". Image:"; on the
  picture's own line it read the picture's inspection and then those nine. The first
  five are UIKit's own for a text view, one for each link of the book by its words, with "￼"
  for a picture or a hidden label in the link: "Jump with decoration" is a link of the
  book's fourth section, offered on a line of its first. In pages, on "Read the numbered
  words across two consecu": "Next Page", "Previous Page", "Inspect Image: Blue verification
  square", "Previous Page", "Next Page", "Activate Default". On the picture's own line the
  inspection came twice: "Next Page", "Previous Page", "Inspect Image: Blue verification
  square", the same again, "Previous Page", "Next Page", "Activate Default".
  The phrases and the rotor were the same at `cfc7768`, before the Headings rotor, and the
  physical iPhone 17 Pro Max of the sessions above said "p005w21 p005w22 p005w23 p005w24
  p005w25 Actions available" in continuous scroll that morning. Neither the rotor nor the
  simulator is the cause.
  A reader built at `cfc7768` to write down what it gives VoiceOver, and to change one thing
  at a time, showed what is. With the cursor on a line of the book of paragraphs the line
  had no action of its own and its text view none; the canvas had "Previous Page" and "Next
  Page", put there by SwiftUI for the reader's surface; and UIKit handed VoiceOver those two
  for the line. In the first book the scroll view had UIKit's five and the reader's "Inspect
  Image: Blue verification square", and a page column the reader's alone. A line cut off
  from what holds it, still answering with an empty list and still answering activation
  itself, was read as "p001w11 p001w12 p001w13 p001w14 p001w15" and no more, and the rotor
  stepped by character ("p Papa", "0", "0"). A line that answered with no list at all, and
  nothing else changed, said "Actions available" as before.
  After, at `69230b2`. Continuous scroll, the book of paragraphs: "Chapter one Heading Use
  the rotor to access Headings", then "p001w01 p001w02 p001w03 p001w04 p001w05", "p001w06
  p001w07 p001w08 p001w09 p001w10" and "p001w11 p001w12 p001w13 p001w14 p001w15" with
  nothing after them, and the flicks read "0", "0", "1", characters of the line. The first
  book: "Read the numbered words across two consecu", and ten flicks read "R Romeo", "e
  Echo", "a Alpha", "d Delta" and on along the line; "Verification link Link", and the
  flicks read "V Victor", "e Echo", "r Romeo"; "Blue verification square Image Actions
  available", and the rotor read "Inspect Image: Blue verification square" and "Activate
  Default" in turn, five times. In pages: "Read the numbered words across two consecu
  Actions available", and the rotor read "Next Page", "Previous Page", "Activate Default"
  and the three again; on "Blue verification square Image" it read "Next Page", "Previous
  Page", "Inspect Image: Blue verification square", "Activate Default" and the first three
  again. At `7934820`, with fifty lines past the screen listed while the cursor is in the
  text, continuous scroll in the first book read the same: "Read the numbered words across
  two consecu Use the rotor to acce" and "R Romeo", "e Echo", "a Alpha"; "Verification link
  Link" and "V Victor", "e Echo", "r Romeo"; "Blue verification square Image Actions
  available" and "Inspect Image: Blue verification square", "Activate Default", "Inspect
  Image: Blue verification square".
  The Mac's load averages were in the hundreds throughout. Three more sessions read
  nothing and were run again: one was not started, one ended with "Failed to send
  moveForward command" and one with "VoiceOver is on but says nothing" after three minutes.
  One session's result is "Critical process xctest crashed" with all its steps in the
  transcript, as under "Other sessions" in [Simulators](#simulators). In the after session
  of the book of paragraphs each phrase was recorded a step late, so the first line is
  there twice and the first flick has the third line's phrase. One simulator came back at
  volume 60 before its VoiceOver had been switched on, and was muted again. After most
  sessions `devicectl` gave no answer in twenty seconds when asked for the simulator's
  VoiceOver state; the simulator was then deleted, as every one was.
  The same evening the physical iPad Air 13-inch (M3) of the sessions above (1024 × 1366,
  upright, 17 points) read the change, built at `8d7397b`, through XCTest's VoiceOver
  service. In pages, with the cursor on "Read the numbered words across two consecutive
  pages. …", four flicks read "Next Page", "Previous Page", "Activate Default" and "Next
  Page", and a double tap on the line then performed Next Page: the page went from
  `word0001`–`word0293` to `word0294`–`word0654`. In continuous scroll the same line left
  the rotor on Headings: the flicks read "Link target reached Heading", "Parked title
  heading Heading", "Parked table heading Heading" and "Pictures and their words Heading",
  the reader scrolling to each, and no action. On the picture's line there the flicks read
  "Inspect Image: Blue verification square" and "Activate Default", and with the first
  chosen a double tap opened the inspector: VoiceOver was on "Zoom Out Button" and a touch
  found "Zoom In Button". An iPad's phrase for a line does not tell whether the line has
  actions. It ended in "Use the rotor to access Headings" for the page's line, which has
  two, and for the same line in continuous scroll, which has none; the rotor tells.
  VoiceOver was off after each session. A first session in pages was deleted with its log
  and result bundle, and run again: a notification arrived on the iPad and was read in
  place of the first flick's phrase.
  Not established: a physical iPhone after the change; a table row's actions under
  VoiceOver, which a unit test holds; and anything on a Mac, where the text areas and the
  surface's two actions are unchanged.
- The same day the section of what each line offers, which shows every kind of item at
  once, was stepped through with the rotor at 17 points in the
  [simulator lane](#simulators) (Xcode 27.0, iOS 27.0, an iPhone 17 Pro and an iPad Air
  13-inch (M4)), before and after the same change made on the branch that reads a table by
  its rows. Nobody listened. The lists are XCTest's record of VoiceOver's phrase after
  each step of one finger down; a phrase that comes twice running in a transcript is one
  entry, heard before and after a step that did not register
  ([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)).
  Before, at `073f2b0`, in pages on both, on "Plain words above.", on the link "Lone jump"
  and on "Plain words below.": "Next Page", "Previous Page", "Inspect Image: Square with
  words", "Inspect Image", "Previous Page", "Next Page", "Activate Default", and round
  again. "Square with words" offered its own inspection third and then the same two
  inspections; the picture without words likewise; the table's row "Select Table Text: Left
  cell", "Select Table Text: Right cell jump" and "Follow Table Link: Right cell jump" after
  the first pair, then the two inspections and the second pair. In continuous scroll on
  both, on a line of words: "Verification link", "￼", "￼", "￼ Jump with decoration", "￼",
  "Lone jump", "Inspect Image: Square with words", "Inspect Image", "Previous Page", "Next
  Page", "Activate Default". Ten actions, none of them the line's; the pictures and the row
  offered their own first and then the same ten.
  A build that put a letter before every action's name for the object that gave it
  (`5c01fa8`, on the iPhone simulator) settled where each came from. On a line of a page:
  "L Next Page" and "L Previous Page" from the line's own element, "K nil" for what UIKit
  returned to the text view, "T Inspect Image: Square with words" and "T Inspect Image"
  from the text view, and "S Previous Page" and "S Next Page" from the reader's SwiftUI
  view. On a line of continuous scroll: "K Verification link", "K ￼", "K ￼", "K ￼ Jump with
  decoration", "K ￼", "K Lone jump" and "K count 6", then the same two T and two S. UIKit's
  six are the book's six runs of text that are links, in the book's order: the first
  section's, the parked link of the hidden labels, the three of the pictures (two of them a
  picture alone) and this section's own. A link in a table cell is not among them, and no
  picture that is not a link.
  After, at `5e6834c` on both, in pages: "Next Page", "Previous Page", "Activate Default"
  on a line and on the link; "Inspect Image: Square with words", or "Inspect Image" on the
  picture without words, before "Activate Default" on a picture; the three table actions
  there on the row; and one turn of the rotor on a line came to Actions. In continuous
  scroll: a step on a line or on the link read the line a character at a time ("P Papa",
  "l Lima"), and thirty turns of the rotor on a line went round Containers, Lines, Words,
  Characters, Headings and Speaking Rate and never came to Actions (`rotor=Actions:
  MISSING`); "Square with words" said "Actions available" and offered "Inspect Image:
  Square with words" and then "Activate Default", the picture without words "Inspect
  Image", and the row its three. `5e6834c` is the change on the table branch's own merge
  with `main`; a session in pages at `918ec8b`, the same change on an earlier merge, read
  the same on both simulators.
  The physical iPad Air 13-inch (M3) of the sessions above (1024 × 1366, upright, 17
  points) read the section in pages at `331c326`, which has the table's rows and the other
  branch's change merged in. "Plain words above." offered "Next Page", "Previous Page" and
  "Activate Default"; "Square with words" those two, "Inspect Image: Square with words" and
  "Activate Default"; and the row began "Next Page", "Previous Page", "Select Table Text:
  Left cell". With Next Page chosen on "Plain words above." a double tap changed the screen,
  and the screenshot shows the page that begins "Below line 18.", where the one before ended
  at "Below line 17.": VoiceOver performed the line's own page turn. VoiceOver was off
  afterward.
  That turn was made with text selected: before it, Select Table Text: Left cell had been
  chosen on the row and performed by a double tap. A second session ran the same two steps
  on a build whose line still turned the page as it used to (`18323fd`, the same revision
  with that one call put back, not in the branch), and there the double tap on Next Page
  changed nothing: "nothing on screen changed in 2.0 s", the first page still in the
  screenshot, and "Words before" for the next move forward. So VoiceOver performs Select
  Table Text on a device, the selection held back a line's page turn as it was, and it does
  not now. The selection itself is not to be seen in either screenshot; the entry of
  2026-10-13 on a table's select action has why, and what shows it now.
  One thing was seen and not looked into: after the turn VoiceOver's cursor was still drawn
  where the line had stood, and a move forward from it went to the book's title under the
  page. The record of 2026-10-13 below has what it was.
  Most sessions started that evening did not run. At load averages of 600 to 1,000
  `devicectl` gave no answer in the runner's twenty seconds when a simulator's volume was
  set, and later failed with "Timed out waiting for CoreDeviceService to fully initialize";
  the iPad simulator's VoiceOver said nothing in three minutes twice; and XCTest failed two
  sessions after their last step ("Critical process xctest crashed"), whose transcripts are
  whole. After the last sessions in continuous scroll `devicectl` could not read back the
  simulators' VoiceOver state; they were deleted, as every one was. One iPhone simulator came back at volume 60 during the labelled continuous-scroll
  session and was muted again by the runner within a second (an `UNMUTED` line).
- On 2026-10-12 the section of scenes was read on a Mac before and after a rule was given an
  element that says a separator is there, and with each other element that was tried
  ([VoiceOver speaks a role's own words](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#voiceover-speaks-a-roles-own-words)).
  GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode
  27.0), a window 600 points wide at 17 points, at the fixed pause. Nobody listened and no
  workstation was used. Before and after were recorded on the same `main` (`5b096d8`).
  Before, at `5b096d8`, runs 38333729257 (pages) and 38333734464 (continuous scroll): as in
  the record above, a phrase with nothing in it on each rule's line, a step with no phrase
  by word, and on the page of a rule alone "In text" and then "end of text". `readall` from
  the page's first word, which that record did not have: "Scenes set apart", "First scene
  ends.", a phrase with nothing in it, "Second scene starts.", the same, "Words after an
  ornament.".
  After, at `e3f5240`, runs 38342098837 (pages) and 38342104207 (continuous scroll). Pages
  by line: "Scenes set apart", "First scene ends.", "Separator", "Second scene starts.",
  "Separator", "Words after an ornament.". By word: "Scenes", "set", "apart", "First",
  "scene", "ends.", "Separator", "Second", "scene", "starts.", "Separator", "Words",
  "after", "an", "ornament.", a step with no phrase, "end of text". `readall` from
  "Scenes": the six phrases heard by line, in order. On the page of a rule alone: "In text
  Separator" on entering, "Separator" for the line and for the word, no phrase for a move
  right, and "end of text" for the next line. Continuous scroll, back by line from
  "scenes.": "Last words of the scenes.", "Separator", "Words after an ornament.",
  "Separator", "Second scene starts.", "Separator", "First scene ends.", "Scenes set
  apart". `readall` from there: a phrase with nothing in it where "First scene ends." is
  read, which the session before the change has too, then "Separator", "Second scene
  starts.", "Separator", "Words after an ornament.", "Separator", "Last words of the
  scenes.". Back by word from "scenes.": a step with no phrase, as before the change, then
  "the", "of", "words", "Last", "Separator", "ornament.", "an", "after", "Words",
  "Separator", "starts.", "scene", "Second". The pages' `LINE` and `STATE` lines are the
  same before and after: a rule's line is two characters of the text area's value, the rule
  and the break after it.
  With `main` at `a49d12e` merged in, which marks headings in the same rich text, at
  `e4b1e22`, run 38342923798, pages: the same six phrases by line and with `readall`, and
  on the page of a rule alone "In text Separator", "Separator" for the line and for the
  word, no phrase for a move right and "end of text". Those two revisions also gave a rule
  in a table cell the element, which the change as it is does not; the scenes hold no
  table. The change as it is, at `6e9b055`, run 38346365216, pages: the same phrases by
  line, by word, with `readall` and on the page of a rule alone as at `e3f5240`. With
  `main` at `449182f` merged in as well, which gives the links of the same rich text
  elements of the reader's own, at `14b2696`, run 38349644406, three sessions in one run:
  "Separator" at every rule in pages by line, with `readall` and by word, on the page of a
  rule alone, and in continuous scroll back by line, with `readall` and back by word. And
  with `main` at `8d78dc1`, whose fixture has a second table in the section before the
  pictures, at `86a5121`, run 38353724021: the scenes' first page is still 22 `ax:next`
  steps in; opened at the section with `-SampleHref OPS/scenes.xhtml`, the same phrases by
  line, with `readall` and by word, and the page of a rule alone one `ax:next` step on; in
  continuous scroll thirty `ax:next` steps and `lastword` gave "scenes.", and the lines
  back from there and `readall` were as before.
  The other elements, each a commit that differs in nothing but what a rule's character
  carries, heard in pages by line, by word, with `readall` and on the page of a rule alone.
  AppKit's splitter role and nothing else, `3073331`, run 38333879354: "horizontal splitter
  collapsed on top" at each rule, with two spaces after "splitter", and "horizontal
  splitter" for `word` on the page of a rule alone; continuous scroll said the same (run
  38333881836). The splitter role with the subrole `AXContentSeparator`, `d664ccf`, run
  38333889187: the same. Those two with the role description "separator", a horizontal
  orientation and not enabled, which is all that WebKit gives an `hr`, `efb3747`, run
  38333903411: "horizontal separator no action available collapsed on top". Static text
  with the value "Separator", `1dd8ea3`, run 38333917655: "Separator", as after. AppKit's
  unknown role with the role description "separator", `563bc29`, run 38339554059:
  "separator" in the same places. Not heard: WebKit's attributes on an element left
  enabled, and any of these but the first in continuous scroll. Their runs were stopped
  while they waited for a runner, once the pages had shown what each says.
  A table cell. At `5b096d8`, run 38333986334, on the page that opens with a table: a move
  by word onto a row said "Table row group", `in` on the second row "In Table row group 2
  items text Third cell" and a move right "text Fourth cell". A row is a group, and each
  cell a text area in it. For two sessions the scenes were given a table at their end, one cell holding
  "Cell scene ends.", a rule and "Cell scene starts."; the fixture in the repository has
  none. At `3f77069`, run 38340763586, with the cell as it is: `in` on the row said "In
  Table row group 2 items text Cell scene ends.", `in` again "In text Cell scene ends.",
  then by line "Cell scene ends.", a phrase with nothing in it, "Cell scene starts.", by
  word a step with no phrase after "ends.", and `readall` the same three phrases as by
  line. At `e1d32b7`, run 38342113877, with the cell's rule given the element a rule has
  outside a table: the same, phrase for phrase.
  Not heard: a physical Mac, or anyone listening; a rule in a note's popover; VoiceOver in
  a language other than English or with its verbosity changed; and what Safari or Books
  says at an `<hr>` on a Mac, which was not compared.
- On 2026-10-12 and 13 links were heard on a Mac
  ([links in an AppKit text view are children, not places](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#links-in-an-appkit-text-view-are-children-not-places)):
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points wide at 17
  points, with VoiceOver's link setting at Speak, as the runner has it. Nobody listened, and
  no workstation was used.
  First what VoiceOver does with AppKit's own text view (`-VerificationPlainText`), with
  TextKit 2 and with TextKit 1, at `e3efd8a`, `a72154c` and `71f9b77`. By word: "the", "reference",
  "link", "after". By line: "Reference opening words. Before the reference link after it."
  and "Picture link:   closing words.". Read All said the same lines. Nothing said that a
  link was there. Find Next Link: "reference link hyperlink", the hint "You are currently on a
  hyperlink, inside of a text area. To clic", then "￼ hyperlink" for the link that is a
  picture. Control-Option-Space after Find Next Link followed the link, and so did
  Control-Option-Space with the cursor on "Reference", the first word of the line that holds
  "reference link", and on "after"; on "Reference" in the last line, which has no link,
  nothing was followed. The rotor listed Window Spots.
  The reader before the change, at `e3efd8a` (main's reader then) and for the pictures at
  `62ea392`: the first page as AppKit's view, "Verification", "link." by word and
  "Verification link hyperlink" for Find Next Link. Its links that are attachments were
  called by their character: `ax:links` gave the titles "￼" and "￼ Jump with decoration",
  and Find Next Link said "￼ hyperlink", "￼ Jump with decoration hyperlink" and "￼
  hyperlink" on the section of pictures, the last for "Described jump". On the hidden-labels
  section Find Next Link did not move to the parked link: VoiceOver said the text area's
  first line again. By word the label was "Parked link to the target" and the pictures
  "image" and "Described jump image", with nothing of a link.
  With the reader's own elements, at `bd27b89`, at the fixed pause, in pages. The first page:
  `ax:links` one child, "Verification link", with `AXPress`; by line "Verification link.
  Image:  Blue verification square image ." and by word "Verification", "link.", as before;
  Find Next Link "Verification link hyperlink" and the hint, and again "Last link
  Verification link hyperlink"; Control-Option-Space from there, and in another session from
  the word "link.", gave `AXValueChanged` with `word1187` to `word1200` and the page whose
  third line is "Link target reached". The hidden labels: by word "closing", "words.",
  "hyperlink Parked link to the target", "Shown"; by line and in Read All "hyperlink Parked
  link to the target Shown last words."; Find Next Link from the top of the page "Parked
  link to the target hyperlink" and the hint, Control-Option-F3 "hyperlink is in the
  VoiceOver cursor", and Control-Option-Space the target's page. The pictures: `ax:links`
  three children, "image", "Jump with decoration" and "Described jump, image"; by line "Bare
  jump:  hyperlink image", "hyperlink  Jump with decoration", "hyperlink Described jump,
  image" and "Titled decoration   passed over."; by word "Bare", "jump:", "hyperlink image",
  "hyperlink", "Jump", "with", "decoration", "hyperlink Described jump, image", "Titled";
  Read All the same lines; Find Next Link "image hyperlink", "Jump with decoration
  hyperlink", "Described jump, image hyperlink", the first and third followed by "actions
  available" before the hint; the actions menu on the third "Actions menu 2 items", "Inspect
  Image: Described jump", "press"; Control-Option-Space on "hyperlink image", reached by
  word, the target's page. `ax:follow` on each section's link gave the same page with
  VoiceOver's cursor elsewhere.
  In continuous scroll at the same revision, opened at a section with `-SampleHref`. The
  text's children were the links of the paragraphs on screen, three with the pictures there,
  one with the hidden labels and one on the first page, while the text's string gave a link
  element at every link of the book. By word, by line and in Read All VoiceOver said what it
  said in pages: "Verification", "link."; "hyperlink Parked link to the target"; "hyperlink
  image", "hyperlink" before "Jump", "hyperlink Described jump, image". Find Next Link gave
  the same names with "hyperlink", and Control-Option-Space from there, and from the word
  "link.", scrolled the view to the target: the insertion point's line was then "Link
  target reached" (`ENTRY`).
  Find Previous Link went forward. From the third link it said "image hyperlink", the
  first, where Find Next Link goes past the last. Main's reader, through AppKit's own
  elements, did the same at `a49d12e`: from the third link "￼ hyperlink" and then "￼ Jump
  with decoration hyperlink", the first and the second. It is VoiceOver's doing on macOS
  27.0.1, as its Find Previous Heading asked the reader for the next heading.
  What did not work, each heard once and left out: a link element given as the attachment of
  a link's words, with a name and without one, over all of them and over the first letter
  (`0b50784`: the first page read as before, by word, by line and in Read All); the same
  over words that follow an attachment (`71f9b77`: VoiceOver said "hyperlink Jump with
  decoration" and then "Jump with decoration" again); and a rotor of links (`8acc907`), with
  the links' characters as its results (Find Next Link "image", "Jump with decoration", "Described jump
  image", without "hyperlink", and Find Previous Link "Link not found") and with the link
  elements as its results (Find Next Link "Link not found", the rotor's list "Link menu",
  "On item image hyperlink").
  Not heard: listening; a workstation; link settings other than Speak, of which Play Tone
  and Change Pitch leave nothing in a transcript; a link in a table cell or a note's
  popover; a link that wraps onto a second line or crosses a page's end, which the unit
  tests read; and a link below the screen in continuous scroll.
- On 2026-10-13 the reader's named actions were looked for on a Mac
  ([SwiftUI puts named actions on the view it hosts](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/accessibility.md#swiftui-puts-named-actions-on-the-view-it-hosts)).
  `NativeSurface` names Next
  Page and Previous Page with SwiftUI's `accessibilityAction(named:)` in both flows, and in
  continuous scroll, which has no pages, the sample's buttons for the same commands are Scroll
  Forward and Scroll Backward. VoiceOver was offered neither action anywhere, in pages or in
  continuous scroll, so nothing is heard under a wrong name and the reader was left as it is.
  [Hosted sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1, macOS 27.0.1
  `26A434`, Xcode 27.0), main's reader at `531a534`, at a fixed pause of four seconds, with
  VoiceOver brought to the column by `ax:focus=search ax:focus=0`: runs 38351606579, 38353526126
  and 38354465519, seventeen sessions. Nobody listened.
  What an assistive client is given, from `ax:actions`. In pages: the window, under it `AXGroup
  AXHostingView` with `ACTIONS none`, and under that one `AXTextArea` for each column with
  `ACTIONS AXShowMenu`. In continuous scroll an `AXScrollArea` with AppKit's
  `AXScrollLeftByPage`, `AXScrollRightByPage`, `AXScrollUpByPage` and `AXScrollDownByPage`
  stands between the group and the one text area. It was the same in one column and in two, at
  17 points and at 23, on a later page, two scroll steps into the book of paragraphs, and after
  `"ax:press=Continuous Scroll"` and `ax:press=Paging` with the reader open. `ax:actions=all`
  found a named action on no element of the window while the sample's controls were embedded,
  and with them in the toolbar only the toolbar's own "Move previous", "Move next" and "Remove
  from toolbar". `"ax:action=Next Page"` printed `MISSING action=Next Page` in both flows, where
  `"ax:action=Move next"` printed `ACTION Move next ON AXButton LABEL "Search" STATUS 0` and the
  toolbar's order changed.
  What VoiceOver said. On the column (Control-Option-F3: "text is in the VoiceOver cursor Line
  1") `actions` gave "Actions menu 1 item" and `listdown` "show menu"; three more `listdown`
  gave nothing, and `listclose` "Closing Actions menu". Inside the text, after `in` ("In text
  Page boundary verifica"), the same two phrases; on the right column of two and on its first
  line on the second spread ("word0324 word0325 word0326 word0327 word0328") the same; in
  continuous scroll on the text area, inside it, and on the line "p006w29 p006w30 p006w31
  p006w32 p006w33 p006w34 p006w35" of the book of paragraphs the same. `"listchoose=show menu"`
  opened the text's contextual menu: "show menu text Page boundary verification", "menu (11
  items)", and under two `listdown` "Look Up “wor”" and "Translate “wor”".
  On the group that holds the columns, which `out` reaches in pages ("Out of group", and
  Control-Option-F3 "Open EPUB… button Open Sample button Close button Use Toolbar bu"),
  `actions` was followed by no phrase, three times in two sessions, and no menu opened: in the
  first session the `listdown` keys after it moved the column's insertion point, and VoiceOver
  read from there ("tion", "Read the numbered words across two consecutive"). With the sample's
  controls in the toolbar the same group said "Actions menu 10 items": "cancel" and "press" four
  times, "show menu" and "cancel", which are the actions of the six elements the group then
  holds, in their order: four buttons, the column and a static text. In continuous scroll `out`
  left the cursor on the text area ("You are currently on a text area."), sent once and sent
  twice.
  Not established. Why the actions reach no element: `ReaderCanvasView`, the view the surface
  wraps, is not an accessibility element on Mac, and where SwiftUI puts a named action of such a
  view was not found. A unit-test host does not show it, so no test holds any of this: there the
  hosting view reports no accessibility children, not even the columns, in either flow, and
  neither it, the view SwiftUI hosts the canvas in nor the canvas has a custom action. What
  VoiceOver's own scroll commands do with the scroll area's four actions, and whether it has
  anything to scroll in pages, where no element has a scroll action. Why the group's menu does
  not open with the controls embedded. Whether VoiceOver ignores its Command-F5 under an open
  Actions menu as under a rotor: the runner closes one first, and in the one session left under
  a menu it wrote `STEP listclose, sent by the runner in case the Actions menu is still open`,
  VoiceOver said "Closing Actions menu" and switched off
  ([VoiceOver state and restoration](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#voiceover-state-and-restoration)).
- Later on 2026-10-13 each text area of the Mac reader was given the page turn as actions of
  its own, named for the flow, and the reader's SwiftUI surface lost its two named actions
  and its scroll action on Mac
  ([custom actions belong on the text area](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#custom-actions-belong-on-the-text-area)).
  It was heard before and after on the same main:
  [hosted sessions](#hosted-mac-sessions) on `xcode-27` (image 20261006.0244.1, macOS 27.0.1
  `26A434`, Xcode 27.0), at a fixed pause of four seconds, with VoiceOver brought to a column
  by `ax:focus=search ax:focus=0`. Before is main's reader at `7fa9231`, run 38364728057.
  After is the reader of `07b233b`, which is that main and the change: runs 38364815359, with
  the eight step lists of the run before, and 38368581010 and 38368509490, which choose the
  actions. Twenty-three sessions; nobody listened.
  What an assistive client is given (`ax:actions`). Before, `AXTextArea ACTIONS AXShowMenu`
  for each column and for the scroll view's text, and `MISSING` for `"ax:action=Next Page"`
  and `"ax:action=Scroll Forward"`. After, `AXTextArea ACTIONS AXShowMenu,"Next
  Page","Previous Page"` for each column, one and two, and `AXShowMenu,"Scroll
  Forward","Scroll Backward"` in continuous scroll, where the scroll area kept AppKit's four
  scrolls by page; the hosting view's group has `ACTIONS none` as before. With the reader
  open, `"ax:press=Continuous Scroll"` changed a column's pair to the scroll's and
  `ax:press=Paging` changed it back.
  VoiceOver's Actions menu. Before, on a column, inside its text, on the right column of two
  and in continuous scroll: "Actions menu 1 item", "show menu". After, in each of those
  places: "Actions menu 3 items", and three `listdown` steps "Previous Page", "show menu",
  "Next Page", or "Scroll Backward", "show menu", "Scroll Forward". A fourth said nothing.
  After each change of flow the menu held the new flow's names.
  The cost. Before, VoiceOver's hint for a text area was "You are currently on a text area,
  inside of a group. To …", or in continuous scroll "You are currently on a text area." and
  "You are currently in a text area. To enter text in this area, ty". After, each begins
  "actions available": "actions available You are currently on a text area, inside of a".
  VoiceOver says the hint about three seconds after it arrives at the column, enters its
  text or returns from the menu, once each time
  ([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)).
  Five moves by line, in pages and in continuous scroll, each read the line and nothing more;
  where a hint followed one of them it was the one still owed for entering the text. Six moves
  by line and two by word at a pause of five seconds read the same way on the reader of
  `c43e88f`, the change on the main before this one (run 38360115206).
  Choosing an action, in pages. In one column, after five moves by line, `"listchoose=Next
  Page"` gave `AXValueChanged` with `word0055` to `word0171` where the page had held
  `word0001` to `word0054`. VoiceOver said "word0055 word0056 word0057 word0058 word0059
  word0060 word0061 w" and "Next Page text  word:  word0055  character:", Control-Option-F3
  "Line 1  word:  word0055  character:  is in the VoiceOver cursor", and `line` "word0055
  word0056 word0057 word0058 word0059 word0060". `"listchoose=Previous Page"` gave the
  first page's words again, "Previous Page text  word:  Page  character:" and "Page boundary
  verification". Chosen with the cursor on the column and not in its text, Next Page turned
  the page and VoiceOver said "Next Page text" and the hint, its cursor still on the column
  ("text is in the VoiceOver cursor Line 1"); `in` then read "In text word0055 word0056
  word0057 word0058 word0059 word0060". On the book's first page Previous Page changed
  nothing, and VoiceOver said "Previous Page text  word:  verification  character:  n", the
  word it was on. A `nextline` straight after a turn moved the insertion point to the
  second line, and its phrase was recorded only when the menu was next used, in both
  sessions in pages.
  In two columns, chosen inside the right-hand one, which held `word0025` to `word0092`.
  Next Page gave `AXValueChanged` for both, `word0093` to `word0160` and `word0161` to
  `word0228`. VoiceOver said "word0161", "Next Page text  word:  word0161  character:" and
  then "text word0093 word0094 word0095 word0096 word0097 word0098 word0": it was on the
  left-hand column ("text is in the VoiceOver cursor Line 1"), and `in` and `line` read
  "word0093 word0094 word0095 word0096". Previous Page from inside that column gave the
  first spread and left VoiceOver in it, on "Page boundary veri". The reader's Page Down
  key, pressed inside the right-hand column, was heard on both readers. Before: "word0161",
  "2 updated items", and Control-Option-F3 "Line 1  word:  word0161  character:  is in the
  VoiceOver cursor", so that the sixty-eight words of the new left-hand column were passed
  over. After: "word0161" and "text word0093 word0094 word0095 word0096 word0097 word0098
  word0", and `line` "word0093 word0094 word0095 word0096".
  In continuous scroll, five lines down. `"listchoose=Scroll Forward"` moved `SELECTION`
  from `271,0` to `865,0`; VoiceOver said "word0078" and "Scroll Forward text  word:
  word0079  character:", Control-Option-F3 "Line 18  word:  word0079", and `line` "word0079
  word0080 word0081 word0082 word0083 word0084". `"listchoose=Scroll Backward"` moved it to
  `27,0`: "Scroll Backward text  word:  Read  character:" and "Read the numbered words
  across two consecutive pages. The next". After a change to continuous scroll with the
  reader open and two moves by line, Scroll Forward gave `SELECTION 703,0` and "Scroll
  Forward text  word:  word0061  character:"; back in pages, on the page that then showed
  `word0055` to `word0171`, Next Page gave `word0172` to `word0285` and "Next Page text
  word:  word0172  character:".
  The group that holds the columns, with the sample's controls in the toolbar and one
  column: "Actions menu 10 items" before and "Actions menu 12 items" after, "cancel" and
  "press" four times, then "Previous Page", "show menu", "Next Page" where "show menu" stood
  alone, then "cancel". With two columns it said 11 before and 15 after, and with the
  controls embedded it opened no menu before or after; those two were heard on the main
  before this one, at `aeb57f0` and at `c43e88f` (runs 38357370635 and 38358026967).
  What stayed as it was. A link reached with Find Next Link ("Verification link hyperlink")
  had "Actions menu 1 item", "press", before and after. And in continuous scroll a step made
  straight after `in`, before VoiceOver had moved inside the text, was undone on both
  readers. With Page Down, before and after: `SELECTION 865,0`, "word0078", "text  word:
  Read  character:  R", then `SELECTION 0,0` and "Page", Control-Option-F3 "Line 1  word:
  Page", and `line` "Page boundary verification", the book's first line. With Scroll Forward
  chosen in the menu, after: the same events and "Scroll Forward text  word:  Read
  character:  R", "Page". After two moves by line the step held, with the key ([continuous
  scroll](#continuous-scroll), step 3) and with the action.
  The status the accessibility API gave `ax:action`. In pages `STATUS 0` for Next Page and
  Previous Page, with the value change, and -25200 for Previous Page on the book's first
  page, where the reader reports that nothing turned. In continuous scroll -25200 for every
  Scroll Forward and Scroll Backward, four times, though each scrolled: `ENTRY` went from
  "word0079" to "word0196" and back, and VoiceOver said the new first word.
  What did not work, heard once and left out, in a reader with switches for it (`f0d9594`,
  runs 38362236673 and 38362411656). The turn made after the action's handler had returned:
  in continuous scroll VoiceOver said "word0078", "text  word:  word0079  character:" and
  then "word0025", and was on "Line 9  word:  word0025", neither where it had been nor the
  new first line; the status in continuous scroll was -25200 all the same, and in pages
  became -25200 where the turn made inside the handler gives 0.
  Not established: why the status in continuous scroll is a failure, and what another
  assistive client makes of it. Why VoiceOver goes back to the start of the text after a
  step it has not moved before, and what would keep it at the new first line, which the
  next entry has. What VoiceOver
  does when a listener has switched off its following of keyboard focus, which is what
  takes it to the first column. Not heard: listening; a workstation; a turn with text
  selected and a turn under `EPUBPageControls.hostOnly`, which unit tests hold and the
  sample has no switch for; a right-to-left spread; a spread whose next section is not
  built yet; and VoiceOver's cursor on a table's row or cell, which keeps its own actions.
- The same day what undid that step was found, and the step made to hold
  ([#464](https://github.com/vocaro/EPUBLib/issues/464),
  [#473](https://github.com/vocaro/EPUBLib/pull/473);
  [VoiceOver enters a text view at its insertion point](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#voiceover-enters-a-text-view-at-its-insertion-point)).
  It was heard before and after on the
  same main: [hosted sessions](#hosted-mac-sessions) on `xcode-27` (image
  20261006.0244.1, macOS 27.0.1 `26A434`, Xcode 27.0), 600 wide at 17 points, at a fixed
  pause of four seconds, with VoiceOver brought to the text by `ax:focus=search ax:focus=0`.
  Before is main's reader at `593b907`, run 38380968267. After is the reader of `aa2fbdb`,
  which is that main and the change, run 38380781111, with the same twelve step lists. For
  a reader changed to continuous scroll while open, four more step lists: before in run
  38386864653, and after in run 38386814468 at `e850a82`, the same change. Nobody listened.
  A step made straight after `in`, in a session launched in continuous scroll. Before, with
  `pagedown`: `SELECTION 865,0`, "word0078", "text  word:  Read  character:  R", then
  `SELECTION 0,0` and "Page"; `describe` "Line 1  word:  Page", `line` "Page boundary
  verification" and `nextline` `SELECTION 26,0`. With `actions`, three `listdown` and
  `"listchoose=Scroll Forward"`: the same, "Scroll Forward text  word:  Read  character:
  R". With `"ax:action=Scroll Forward"` and with the host's button pressed natively
  (`ax:next`): the same. After, each of the four: two `AXSelectedTextChanged` with
  `SELECTION 865,0` and none after them, "word0078", "text  word:  word0079  character:
  w", which the menu's choice begins with the action's name, `describe` "Line 18  word:
  word0079", `line` "word0079 word0080 word0081 word0082 word0083 word0084" and `nextline`
  `SELECTION 919,0`. A second `pagedown` went on to `SELECTION 1918,0`, "word0195" and "text
  word:  word0196", and `pageup` came back to 865 with "word0079". Before, the second went
  from the top of the book to 703 and `pageup` to 0.
  What read the same before and after. After two moves by line, `pagedown` and the menu's
  Scroll Forward: `SELECTION 865,0`, "word0078", "text  word:  word0079  character:",
  "Line 18". VoiceOver two lines down, out of the text and one item right, a native press
  of Scroll Forward, back and `in`: "word0078" at the press and "In text word0079 word0080
  word0081 word0082 word0083 word0084". VoiceOver
  resting on the text area, `pagedown`: "word0078", "text Page boundary verification" and
  the text's first sentence, `describe` "text is in the VoiceOver cursor Line 18", `in` "In
  text word0079…". In pages, `in`, `nextline` and `pagedown`: "word0055 word0056 word0057",
  "text  word:  word0055", "Line 1". A page turn shows two `AXSelectedTextChanged` for each
  column on both readers, from the text put into it.
  A reader changed to continuous scroll while open, with nothing focused first
  (`"ax:press=Continuous Scroll" ax:focus=0 in`, which enters at "In text Page boundary
  verification"). Before, with `pagedown`: `SELECTION 703,0`, "word0060", "text  word:  Page
  character:  P", `SELECTION 0,0`, "Page", "Line 1  word:  Page", and `line` "Page boundary
  verification". With the menu's Scroll Forward: "Scroll Forward text  word:  Page
  character:  P", `SELECTION 0,0` and the same line. After, both: two
  `AXSelectedTextChanged` with `SELECTION 703,0`, "word0060", "text  word:  word0061", with
  the action's name before it from the menu, "Line 15  word:  word0061", `line` "word0061
  word0062 word0063 word0064 word0065 word0066", and after the key `nextline`
  `SELECTION 757,0`. After two moves by line there, `pagedown` read "word0060", "text
  word:  word0061" and "Line 15" before and after.
  The same change of flow with a column given keyboard focus first (`ax:focus=search
  ax:focus=0` before the press) held on main: `pagedown` straight after `in`, and after two
  moves by line, and the menu's Scroll Forward straight after `in`, each `SELECTION 703,0`,
  "word0060", "text  word:  word0061" and "Line 15", before and after.
  A phrase begun twice, on either reader. With the menu's Scroll Forward VoiceOver recorded
  "text  word:  word0079  character:" and, 54 ms later, "Scroll Forward text  word:
  word0079  character:" once in the reader with the change (after two moves by line) and
  the same pair for word0061 once on main (after the change of flow with a column focused
  first), where the other sessions that choose the action have the second alone. It is
  not the change's.
  How it was found, in a reader that logs what VoiceOver asks of the text (the entry on
  that, above; `47b700e`, `c293516` and `24c58c0`, runs 38373719273, 38376212379 and
  38378765133, thirty-four sessions over the mains of `6d9be92` and `593b907`). The step
  moves the insertion point from 27 to 865, and AppKit posts one `AXSelectedTextChanged`.
  VoiceOver reads the selected range, the 838 characters between the two places, the
  insertion point's line and the words around it, says "word0078", and asks no more. At the
  window's layout change it asks for the bounds of characters 27 to 90, the line it entered
  at, and the scroll view goes to the top through `-[NSScrollView
  _doScroller:hitPart:multiplier:]`: VoiceOver sets the scroll bar's value. The reader takes
  that scroll for anybody's and 150 ms later puts the insertion point on the first line then
  on screen, character 0, and that second move VoiceOver follows. After two moves by line
  the same queries end with the bounds of characters 865 to 919: VoiceOver is on the new
  line at the one notice.
  What was tried, each in the session that fails; none changed the session that holds. No
  layout change: "word0078" and nothing more, then at `describe` the scroll back, "Line 18
  word:  Read" and `SELECTION 0,0`. The layout change posted by the text view, which is its
  own unignored ancestor: VoiceOver set `SELECTION 163,0`, the first character AppKit counts
  as visible, and was on "Line 5  word:  word0001". Posted by the canvas's unignored
  ancestor: as with none. Posted before the insertion point moved: as on main. A second
  `AXSelectedTextChanged` posted after the layout change: as on main. The insertion point
  put on the step's first line before the view scrolled: as on main. An insertion point set
  by a client within a second of the step refused: VoiceOver sets none. The view put back after
  VoiceOver's scroll: "Line 18  word:  Read", and VoiceOver scrolled again at its next
  command. The insertion point kept where it was through VoiceOver's scroll: the view at
  the top and "Line 18  word:  Page". The insertion point moved twice, to the line after
  and then to the first line, before the scroll or after it: held. Moved once, with a
  second `AXSelectedTextChanged` posted by the text view before the layout change: held,
  and that is the change.
  Where one notice was enough: after the change of flow with a column focused first. The
  reader gives the new text keyboard focus itself there, and VoiceOver read `AXFocused` at
  `in` and did not set it, in both such sessions logged. In each of the nineteen logged
  sessions launched in continuous scroll it set `AXFocused` on the text at `in`, the
  sessions that hold among them, where the selection VoiceOver sets as it moves by line
  comes before the reader's. So every logged session agrees with VoiceOver passing over
  the first change of selection after it has set keyboard focus on a text. That this is
  its rule was not established, and the change of flow with nothing focused first, which
  fails on main, was not logged.
  The status of `ax:action`: -25200 for Scroll Forward, before and after, though the view
  scrolled and VoiceOver said the new first word. The reader's handler returns true. Its
  return was logged under `_NSAccessibilityPerformActionCustom`, called from
  `NSAccessibilityEntryPointPerformAction`, and the observer had the status 7 ms later. So
  the failure is AppKit's answer and not the reader's. Why AppKit gives it in continuous
  scroll and 0 in pages was not found
  ([#465](https://github.com/vocaro/EPUBLib/issues/465)).
  Seen besides: a session launched in continuous scroll does not begin at the top of the
  book. `ax:width` ends a live resize, and AppKit's text view then scrolls itself
  (`-[NSTextView viewDidEndLiveResize]`, `scrollToLocation:`) 48 points down
  ([offscreen AppKit hosting](https://github.com/vocaro/apple-engineering/blob/main/guides/background-mac-testing.md#offscreen-appkit-hosting)).
  The book's title is then above the screen, the insertion point follows to character 27, and `in`
  reads the second line, as in every such session here. A session that changes to
  continuous scroll after the resize begins at the top. Any live resize did the same, and
  away from the top of a book it took the text back a paragraph; the reader has held its
  place through one since [#479](https://github.com/vocaro/EPUBLib/pull/479) (the note on
  `ax:width` at the head of this list).
  Not established: why VoiceOver keeps its cursor for one notice and follows two. Not
  heard: listening; a workstation; a move to a shown position (the contents, a search
  result) or rebuilt text with VoiceOver inside the text, which post the same second
  notice, as a unit test holds for the contents; the insertion point following a scroll by
  hand while VoiceOver is inside the text and has not moved, which posts one notice as
  before; and another assistive client.
- On 2026-10-13 VoiceOver's Read Line was heard in a table cell on a Mac, before and after a
  cell gave a line for the end of its text
  ([AppKit gives a client the text character for character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#appkit-gives-a-client-the-text-character-for-character)).
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), VoiceOver's link setting Speak, a
  window 600 points wide, at the fixed pause. Nobody listened and no workstation was used.
  Before is `main` at `0128fa6`, runs 38360769105 and 38363804998. After is `774f82c`, that
  `main` with the change, runs 38361875335 and 38363855146. Each step list was run on both.
  The two readers differ in one answer, the line of the offset after a cell's last
  character, so what changed in the speech is what VoiceOver asks of that offset. The
  observer prints no cell's selection; in a page's text the selection after `right` is the
  end of the word VoiceOver said, `SELECTION 7,0` after "Entries".
  A cell of one line, "Third cell" in the section with a hidden heading over a table, at 17
  points: in pages `"launch=-SampleHref OPS/table.xhtml" "ax:caret=Shown words after"
  ax:focus=search ax:focus=0 in left in in`, and in continuous scroll the same with
  `ax:focus` for the two focus steps. Both readers, in both flows: "In text Shown words
  after the table.", "Table row group", "In Table row group 2 items text Third cell" and
  "In text Third cell"; `line` said "Third cell" on entering, and again after `right` had
  said "Third". After the next `right`, "cell", `line` said nothing before and "Third cell"
  after. After one more, "end of text", the same: nothing, and then "Third cell". In pages
  `textend` said "end of text end of text" and `line` after it nothing before and "Third
  cell" after, and after `firstword`, "Third", `line` said "Third cell" in both. With the
  cursor on "cell", `describe` said "word: cell end of text is in the VoiceOver cursor" in
  both, and `linecount` "-9,223,372,036,854,775,808 lines 9,223,372,036,854,775,808 visib"
  before, the 64 characters the probe records, and "1 line 1 visible line" after.
  A cell whose words are a link, "Right cell jump" in the section of what each line offers
  (`"launch=-SampleHref OPS/offers.xhtml" "ax:caret=Plain words below" ax:focus=search
  ax:focus=0 in left in right in`): "In Table row group 2 items text Left cell", "text
  Right cell jump" and "In text Right cell jump" in both, and `line` "Right cell jump" on
  entering. After "Right", "cell" and "jump" by word `line` said nothing before and "Right
  cell jump" after, and the same after "end of text".
  A cell of two lines. At 56 points the first table's cells read "First" over "cell", and
  the page holds the hidden heading and the table's two rows and nothing else
  (`text_size=56 "launch=-SampleHref OPS/table.xhtml" ax:focus=search ax:focus=0 in right
  right in in`): "In text Parked table heading", "Parked table heading", "Table row group",
  "In Table row group 2 items text First cell" and "In text First" in both, and `line`
  "First" on entering and after `right` had said "First". After the next `right`, "cell",
  `describe` said "word: cell end of text is in the VoiceOver cursor" before and "Line 2
  word: cell end of text is in the VoiceOver cursor Line" after. `line` then said nothing
  before and "cell" after, and the same after "end of text". From there `previousline` and
  `nextline` said nothing before, and "First" and "cell" after: without a line for the end
  of its text a cell gave VoiceOver no line to move from either.
  The probe records a phrase VoiceOver repeats once. In a cell whose last line is one word,
  `line` straight after `right` has said that word shows no new phrase in either reader, as
  in the fourth session of run 38361875335; the sessions above have `describe` between the
  two. A session at 56 points that looked for "Shown words after" (run 38360769105) found
  the line on the next page and never reached a cell.
  Cells that hold a picture, a formula or a hidden label. `main` gained the section of
  entries while these were recorded, so its cells were heard on that `main`, `7fa9231`, run
  38365047824, and on the change merged with it, `bee900d`, run 38365114165, at 17 points
  with the reader opened at the section, the same four sessions in each. In all four cells
  both readers said the same up to the last word, and with the cursor on it `describe` said
  "word: shown. end of text is in the VoiceOver cursor", or the cell's own last word in
  that place, with "Line 2" before it after the change in a cell of two lines. Then, for
  `line` on the last word and again after "end of text": in the described picture's cell,
  nothing before and "Drawn Blue entry square image shown." after; in the hidden label's,
  whose lines are "Parked entry words. Seen entry" and "words.", nothing before and "words."
  after, and `previousline` from there nothing before and "Parked entry words. Seen entry"
  after; in the formula's, in continuous scroll, nothing before and "stated." after, and
  `previousline` nothing before and "Sum x squared image" after; in the cell of the picture
  nobody describes, whose second line opens with the picture, nothing before and "image
  stands." after. The session on "Third cell" in pages said at `bee900d` what it had said
  at `774f82c`, phrase for phrase.
  A picture's actions in a cell, and the cells of the section of entries in continuous
  scroll, which the record of that section left unheard: at `d3e1f87`, #453's branch before
  `main` was last merged into it, runs 38361206010 and 38362735530, with the reader opened
  at the section. A cell's code there is what `main` has had since #453 merged.
  Four `right` steps from the text's first line reach the second row, `in` twice enters the
  described picture's cell and two `right` steps put VoiceOver on the picture, "Blue entry
  square image". `actions` there said "Actions menu 2 items", `listdown` "show menu" and a
  second `listdown` "Inspect Image: Blue entry square"; on the picture nobody describes the
  second was "Inspect Image". `"listchoose=Inspect Image"` then opened the inspector, in
  pages and in continuous scroll: `ax:actions=all` printed Zoom Out, Zoom In, Fit, Close,
  "Magnification" and an image called "Blue entry square", or one with no name, and the
  application posted the value "100%". VoiceOver said "Inspect Image: Blue entry square
  text Drawn Blue entry square i" and for `describe`, in pages, "text is in the VoiceOver
  cursor Line 3": its cursor stayed on the text and did not go to the inspector. Whether it
  goes there from a picture in a page's own text was not compared. "show menu" is the menu's first
  item, so one `listdown` before `"listchoose=Inspect Image"` chooses nothing and the
  runner stops the session, as it did the second of run 38361206010. In continuous scroll
  the cells said what they say in pages: "In text Drawn Blue entry square image shown." and
  "Blue entry square image" by word; "text Parked entry words. Seen entry words." and
  "Parked entry words." by word; "text Sum x squared image stated." and "x squared image"
  by word; "Ornament", a step with no phrase and "passed."; "Undescribed", "image" and
  "stands.". From the first row there, two `out` steps and `right` said "Drawn Blue entry
  square shown. Parked entry words. Seen entry wo" at the second row, its cells' words,
  and the next `right` "Table row group".
  Not heard: a part of a cell cut at a page's end, which is unit-tested
  (`TableCellLineAccessibilityTests`); a cell whose last character is a picture or a
  formula; a physical Mac, or anyone listening.
- On 2026-10-12 the section with a hidden heading over a table, with its second table, was
  read at 17 points before and after a table's rows became single items: at `2053be8` and at
  `1e3e5c3`, in the [simulator lane](#simulators) (Xcode 27.0, iOS 27.0, an iPhone 17 Pro and
  an iPad Air 13-inch (M4)), in pages and in continuous scroll. Before, in pages, sixteen
  moves forward from Bookmark gave the eight cells of both tables, each an item ("First
  cell" to "Eighth cell link Double tap to activate embedded link"), then "Parked table
  heading", "First cell Second cell Image", "Third cell Fourth cell Image", "Shown words
  after the table.", two lines, "Fifth cell Sixth cell Image" and "Seventh cell Eighth cell
  link Image"; moving back from "Parked table heading" gave "First cell" and then Bookmark.
  In continuous scroll the rows came where they stand, each as an image, and no cell before
  them; but a touch on a cell put the cursor on the cell, and on the iPhone, where reading on
  had scrolled the view, moving back left the text at "Line 02 after the table." by way of
  the second table's four cells. In both flows the rotor offered Select Table Text for every
  cell on screen on any line, in pages after Next Page and Previous Page. After, in both
  flows on both simulators: "Parked table heading", "First cell Second cell", "Third cell
  Fourth cell", "Shown words after the table.", "Line 01 after the table.", "Line 02 after
  the table.", "Fifth cell Sixth cell", "Seventh cell Eighth cell link", "Line 03 after the
  table." and on, with no cell by itself and no "Image", and the same items in reverse on
  the way back, to Bookmark in pages and to the last line of the section before in
  continuous scroll. A touch on the last row put the cursor on the row. There the rotor offered
  Select Table Text: Seventh cell, Select Table Text: Eighth cell link and Follow Table
  Link: Eighth cell link, after Next Page and Previous Page in pages, and on "Line 03 after
  the table." none of the three. Two things are not this change's. In continuous scroll on
  the iPhone, moving back left the text at "Line 02 after the table." for Bookmark in one
  session of two at `1e3e5c3`, as it had at `2053be8`; a session at `1e0eb8c`, seven commits
  of main earlier, and every iPad session read back to the heading. And in continuous scroll
  the rotor offered on every line, before and after, "Verification link", "￼" and "Inspect
  Image"; the first is a link in the book's first section.
- The same day a physical iPad Air 13-inch (M3) (iPadOS 27.2, 1024 × 1366) read the section
  at `1e3e5c3` in both flows as the simulators had, forward and back, and VoiceOver followed
  the link in the cell: with Follow Table Link: Eighth cell link chosen in the rotor, the
  fifth action in pages and the third in continuous scroll, a double tap on the row changed
  the screen and a touch then found "Link target reached". VoiceOver was off afterward. The
  physical iPhone 17 Pro Max (iOS 27.2, 440 × 956) gave no result at first: one run ended in
  "Timed out while enabling automation mode", and a second lost its authorization for UI
  testing after eighteen seconds, with another app's control under VoiceOver's cursor, and
  left VoiceOver on. Later, with the phone free, it read the section at `edb13b1`, which has
  the changes to images, rules and headings merged in, as the iPad had. In pages: "Parked
  table heading" as a heading, the rows where they stand, on to "Line 06 after the table."
  at the foot of the page, and back to Bookmark. In continuous scroll: on to "Line 10 after
  the table." and back past the heading to the last line of the section before. In both
  flows a double tap with Follow Table Link: Eighth cell link chosen opened "Link target
  reached". A notification from another app took the place of one phrase in two sessions, a
  move forward in pages and a step of the rotor in continuous scroll. xcodebuild took nearly
  five minutes to start a session on the phone while the Mac was busy, so a deadline of five
  minutes stopped the first continuous scroll session part way through the rotor and left
  VoiceOver on; the rotor steps were run again alone. Each time VoiceOver was left on it was
  switched off with `devicectl device settings voiceover --disable` and read back as off
  ([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).
  Nobody listened to any of these sessions.
- On 2026-10-12 the three sections of tables were read at 17 points before and after a table
  of data was given to VoiceOver cell by cell
  ([on iOS a data table is a container among the lines](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#on-ios-a-data-table-is-a-container-among-the-lines)):
  before at `17a4a36`, which is main with #382
  and this change's fixture and probe, and after at `bc473cb`. Nobody listened; the phrases
  are XCTest's record of VoiceOver's speech.
  In the [simulator lane](#simulators) (Xcode 27.0, iOS 27.0, an iPhone 17 Pro and an iPad Air
  13-inch (M4)), moving forward from Bookmark on the section of tables of data, in pages.
  Before, a row was an item: "Stations on the branch", "Station Opened Depth", "Alder 1901
  Twelve metres", "Birch 1934", "Cedar Reopened 1978 Forty metres", "Words between the
  grids.", "Service Hours", "Leaves Arrives", "Express Nine Noon", "Stopper Ten Three",
  "Nothing on Sunday", then "Left side Right side", "Lower left Lower right", "North Wet" and
  "South Dry"; on the last row of the first table the rotor offered Next Page, Previous Page,
  Select Table Text for each of its three cells and Follow Table Link: Reopened 1978. After:
  "Stations on the branch", "Station Column header Row 1 Column 1 Table start 4 rows 3
  column" (the 64 characters a simulator's phrase has), "Opened Column header Column 2",
  "Depth Column header Column 3", "Station Alder Row header Row 2 Column 1", "Opened 1901
  Column 2", "Depth Twelve metres Column 3", "Station Birch Row header Row 3 Column 1",
  "Opened 1934 Column 2", "Depth Column 3" for the empty cell, "Station Cedar Row header Row
  4 Column 1", "Opened Reopened 1978 Column 2 Link", "Depth Forty metres Column 3 Table end";
  in the second table "Service Column header Spans 2 rows Row 1 Column 1 Table start",
  "Hours Column header Spans 2 columns Column 2", "Leaves Column header Row 2 Column 2",
  "Arrives Column header Column 3", "Service Express Row 3 Column 1", "Hours Leaves Nine
  Column 2", "Arrives Noon Column 3", "Service Stopper Spans 2 rows Row 4 Column 1", "Hours
  Leaves Ten Column 2", "Arrives Three Column 3", "Leaves Nothing on Sunday Spans 2 columns
  Row 5 Column 2 Table en"; then "Left side Right side" and "Lower left Lower right" as
  before, for the table with `role="presentation"`, and "North Row 1 Column 1 Table start 2
  rows 2 columns", "Wet Column 2", "South Row 2 Column 1", "Dry Column 2 Table end" for the
  ruled table of plain cells. VoiceOver says a header cell's words before a cell only when
  they differ from the cell before's, and so on the way back: "Alder Depth Twelve metres Row
  2 Column 3". The iPhone's first page ends after the first table and read the same. With
  the rotor on Rows from "Alder": "Birch Row header Row 3", "Cedar Row header Row 4", where
  it stays, and back up to "Station Column header Row 1 Table start 4 rows 3 columns"; from
  "Nine" on the iPad: "Ten Row 4", "Nothing on Sunday Spans 2 columns Row 5 Table end", and
  up to "Leaves Column header Row 2" and "Hours Column header Spans 2 columns Row 1". On
  "Reopened 1978" the rotor offered Next Page, Previous Page, Select Cell Text and Follow
  Link: Reopened 1978. With the rotor on Headings, from a cell, `flick=up` went to "Tables of
  data Heading". In continuous scroll on the iPad the same items came forward and back, and
  the cell offered Select Cell Text and Follow Link: Reopened 1978.
  On the section with a table longer than a page, in continuous scroll, 136 moves forward
  and 136 back on each simulator: every one of the 120 cells below the header row once and
  in order each way, "Entry Entry 13 Row 14 Column 1", "Item Item 13 Column 2", past the
  screen, to "Sum Sum 40 Column 3 Table end" and "Words after the ledger.", and back from
  "Sum 40 Row 41 Column 3 Table end" through "Sum Sum 39 Row 40 Column 3", where the header
  row is forty rows above the screen, to "Words before the ledger.". Before, the rows came
  in order as "Entry 13 Item 13 Sum 13". In pages on the iPad: the first page to "Item Item
  14 Column 2" in 46 moves; after Next Page "Entry 28 Row 29 Column 1 Table start 41 rows 3
  columns", "Item Item 28 Column 2", "Sum Sum 28 Column 3", "Entry Entry 29 Row 30 Column 1",
  and with the rotor on Rows "Item 31 Row 32" to "Item 33 Row 34" and back up to "Item 28 Row
  29". An earlier session of the same steps on the iPhone, at a load average near 600, did
  not turn the page: its double tap on Next Page changed nothing in two seconds.
  On the row taller than a page, in continuous scroll on the iPad: "Clause Column header Row
  1 Column 1 Table start 3 rows 2 columns", "Wording Column header Column 2", "Clause Tall
  clause Row 2 Column 1", one item for the tall cell, "Wording t0001 t0002" and on, "Clause
  Short clause Row 3 Column 1", "Wording Short wording Column 2 Table end", and the same
  back. In pages on the iPhone the short cell beside the tall one was a stop that said only
  "Row 2 Column 1" on the row's first page: the cell is centred in a row ten pages tall, so
  its words stand some pages in. A cell is since listed on the page where it has something
  to say, and at `1c4f136` that page began with the tall cell, "t0001 t0002".
  **One thing went wrong before main's list of fifty lines past the screen was merged in,
  on the simulator alone.** In continuous scroll on the iPad
  simulator, reading on from Bookmark to "Line 10 after the grids.", which scrolls the view
  until the first table's header row lies under the reader's top inset, and then back, left
  the text at "Station Alder Row header Column 1" for Bookmark in two sessions of three at
  `bc473cb`, with the header row, the caption and two lines above them unread; the third
  read back through "Depth Column header Row 1 Column 3" to "Tables of data Heading". The
  same steps before the change, at `17a4a36`, read back through "Station Opened Depth" to
  "Tables of data" and the section before in two sessions of two, and the physical iPad at
  `1c4f136` did so cell by cell in two of two, the second from "Line 24 after the grids.".
  Reading back through the long table, which scrolls the view at every row, was complete on
  both simulators, and the iPhone simulator read the same section on to "Line 10 after
  the grids." and back complete in its one session. The thirty-nine items it read back
  before leaving are those that were listed before "Line 10" at the moment it turned
  round, two lines above the first on screen, which is what
  [#339](https://github.com/vocaro/EPUBLib/issues/339) describes; why the rows before this
  change did not show it there is not known. At
  `25ae60e`, with main merged in and fifty lines listed each side
  ([#380](https://github.com/vocaro/EPUBLib/pull/380)), the same steps on the iPad
  simulator read back complete in two sessions of two, through "Depth Column header Row 1
  Column 3" and "Stations on the branch" to "Tables of data Heading" and "Last words of the
  scenes.".
  The sessions ran while the Mac's load average stood between 400 and 1,000. Sessions at an
  earlier revision of this change, before the probe waited out a repeated phrase, recorded
  one cell twice and the next not at all here and there, and on the iPad simulator 136
  moves forward reached only the ninety-sixth cell while the 136 back gave every cell; the
  counts showed the first to be the record and not the reader. One session's touch on "Item
  02" at 28 points found nothing on the iPhone simulator. At 17 points and `1c4f136`, with
  the rotor on Rows, twenty-six flicks down from "Item 02 Row 3" went a row at a time to
  "Item 28", past the screen; ten flicks up came back a row at a time to "Item 18", and the
  flicks after that stepped through actions instead, "Select Cell Text", "Verification
  link", "￼": the rotor was on Actions. A cell offers Select Cell Text only once it is on
  screen, where its interaction surface is. The physical iPad made seventy such flicks
  without the rotor moving. In one more iPhone simulator session, after a walk to "Line 10"
  and back, a flick down with the rotor on Rows from "Alder" went to "Last words of the
  scenes." and the flicks after it stepped through actions; the iPad simulator and the
  iPad moved to "Birch" at the same step. At `25ae60e`, with main merged in, the iPhone
  simulator made the twenty-six flicks down to "Item 28 Row 29" and twenty-eight back up,
  a row at a time to "Item 01 Row 2" and "Item Column header Row 1", with the rotor on
  Rows throughout, and read the long table's 120 cells once and in order each way in 136
  moves. In pages on the iPhone the long table's second
  page began "Entry 06 Row 7 Column 1 Table start 41 rows 3 columns", "Item Item 06 Column
  2", and Rows moved from "Item 08" down to "Item 11 Row 12" and back up to "Item 06 Row 7".
- The same day a physical iPad Air 13-inch (M3) (iPadOS 27.2, 1024 × 1366) read the same
  sections at `bc473cb`, and at `7d8e7f4` for the rotor's Rows, which differs from it in the
  probe and one test. In pages on the tables of data, the simulators' items with whole
  phrases: "Station Column header Row 1 Column 1 Table start 4 rows 3 columns", "Leaves
  Nothing on Sunday Spans 2 columns Row 5 Column 2 Table end". With Follow Link: Reopened
  1978 chosen in the rotor, the fourth action in pages and the second in continuous scroll,
  a double tap on the cell changed the screen and a touch then found "Link target reached
  Heading"; a plain double tap on the cell, with no action chosen, did the same. With
  Select Cell Text chosen, a double tap gave "Select Cell Text" and the screenshot shows
  VoiceOver's cursor on the cell's box and no highlight in it: that the words were selected
  there is shown by the unit test only (the entry of 2026-10-13 below shows it on the
  device, and what the action does now). The rotor's Rows moved down and up a column in both
  tables as on the simulators. In continuous scroll at 23 points, 136 moves forward and 136
  back through the long table gave all 120 cells once and in order each way; at 28 points,
  with the rotor on Rows, thirty-four flicks down from "Item 02 Row 3" went a row at a time
  to "Item 36 Row 37", past the screen, and thirty-six up went back to "Item 01 Row 2" and
  "Item Column header Row 1". In pages at 23 points the page after the first began "Entry
  19 Row 20 Column 1 Table start 41 rows 3 columns", "Item Item 19 Column 2". On the row
  taller than a page: "Clause Column header Row 1 Column 1 Table start 3 rows 2 columns"
  and "Wording Column header Column 2 Table end" on the first page, and after Next Page
  "Tall clause Row 2 Column 1 Table start 3 rows 2 columns" and one item for the tall cell,
  "Wording t0001 t0002" and on to `t1707`, the words that page shows. The probe's two-finger
  turns came round to the same five rotor settings on this iPad, none of them Rows, until
  it made its smallest turn alone, which moved one setting at a time. VoiceOver was off
  after every session, and the iPad was claimed in the shared file for the half hour. At
  `1c4f136`, the last change to the reader, two more sessions in continuous scroll read on
  to "Line 10 after the grids." and to "Line 24 after the grids." and back, every item in
  order to "Tables of data Heading" and "Last words of the scenes."; and at `791b57f`,
  which differs from it in where a cell of a row several pages tall is listed, the walk
  through the tables of data in pages matched the first session's phrase for phrase, the
  link was followed again, and the long table gave its 120 cells once and in order each
  way. At `25ae60e`, with main merged in and fifty lines listed past the screen, the walk in
  pages and the walk on to "Line 10 after the grids." and back in continuous scroll gave the
  phrases they had given before, the link was followed, and the long table gave its 120
  cells once and in order each way. The physical iPhone was not used.
- On 2026-10-13 the section of entries was read on a Mac before and after a table cell kept
  the elements it gives for its attachments
  ([AppKit gives a client the text character for character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#appkit-gives-a-client-the-text-character-for-character)).
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), a window 600 points wide at 17
  points, at the fixed pause, the reader opened at the section. Nobody listened and no
  workstation was used. Before and after were recorded on the same `main` (`aeb57f0`), each
  as one run of the same five sessions: the first row's two cells, the second row's, the
  formula after the table, the first row's first cell in continuous scroll, and the third
  row's two cells with the fourth row's first. The table's second column is narrow there:
  its cells wrap after "Sum" and the formula, after "Seen entry" and after "Undescribed",
  so a cell's first line is not all of it.
  Before, at `c5e984e`, which is that `main` with the section and nothing else, run
  38357791945. On entering the first row: "In Table row group 2 items text Upper part
  closes." and a phrase with nothing in it. In the rule's cell by line: "Upper part
  closes.", a phrase with nothing in it, "Lower half opens."; by word: "Upper", "part",
  "closes.", a step with no phrase, "Lower", "half", "opens."; `readall`: the three phrases
  heard by line. The formula's cell: "text Sum stated." on moving to it, "In text Sum" and
  "Sum" for its first line, by word "Sum", a step with no phrase, "stated.", and `readall`
  "Sum stated.". The picture's: "In Table row group 2 items text Drawn shown.", by word
  "Drawn", a step with no phrase, "shown.", `readall` "Drawn shown.". The hidden label's:
  "text Seen entry words.", by line "Seen entry" and "words.", no phrase for `firstword` or
  the step after it, then "Seen", "entry", "words.", and `readall` "Seen entry words.". The
  decoration's: "Ornament passed.", by word "Ornament", a step with no phrase, "passed.".
  The undescribed picture's: "text Undescribed stands.", by line "Undescribed" and
  "stands.", by word "Undescribed", a step with no phrase, "stands.". The cell that holds a
  table: "In Table row group 2 items text" and no more, "In text", and no phrase for the
  line, a word or `readall`. In continuous scroll the rule's cell read as in pages, a
  phrase with nothing in it on the rule's line and in `readall`.
  After, at `9cd0493`, run 38357859452. On entering the first row: "In Table row group 2
  items text Upper part closes." and "Separator". In the rule's cell by line: "Upper part
  closes.", "Separator", "Lower half opens."; by word: "Upper", "part", "closes.",
  "Separator", "Lower", "half", "opens."; `readall`: the three phrases heard by line. The
  formula's cell: "text Sum x squared image stated." on moving to it, "Sum x squared image"
  for its first line, by word "Sum", "x squared image", "stated.", and `readall` "Sum x
  squared image stated.". The picture's: "In text Drawn Blue entry square image shown.", by
  word "Drawn", "Blue entry square image", "shown.", and the same line for `readall`. The
  hidden label's: "text Parked entry words. Seen entry words.", by line "Parked entry
  words. Seen entry" and "words.", "Parked entry words." for `firstword`, then "Seen",
  "entry", "words.", and `readall` "Parked entry words. Seen entry words.". The
  decoration's as before: "Ornament passed.", with one step by word that has no phrase.
  The undescribed picture's: "text Undescribed image stands.", by line "Undescribed" and
  "image stands.", by word "Undescribed", "image", "stands.", and `readall` "Undescribed
  image stands.". The cell that holds a table: "In Table row group 2 items text Inner one
  Inner two", "In text Inner one Inner two", and the same words for the line; no further
  phrase was recorded for a word or `readall`, which a repeat of those words would not be.
  In continuous scroll the rule's cell: "Separator" after the row's first words on
  entering, on the rule's line and in `readall`.
  The same before and after: the formula in the page's own text, "In text Beyond them y
  cubed image ends.", by word "Beyond", "them", "y cubed image", "ends."; so a formula in a
  cell is now read as one outside a cell is. Leaving the picture's cell VoiceOver said "Out
  of text" and "actions available", for the cell's own Inspect Image action. The `LINE`
  lines of the page are the same: each row is two characters of the page's text, the row
  and the break after it. From the third row, two `out` steps and `right` reached the
  fourth; VoiceOver said "Undescribed" there, the first word of the cell it had left, and
  after the change "Table row" as well.
  Why a cell's elements were not read was found first, on `main` at `7b0cce2` with the
  section as it then was: three rows, and "Entries are over." after the table. A cell
  differed from a page's text in two things, and each was changed alone, with a rule given
  the element it has outside a table in both and nothing else touched, three sessions
  each: the rule's cell, the formula's and the picture's. With the elements kept from one
  read to the next and given no frame, at `0c979b4`, run 38356001122: "Separator" on
  entering the row, by line, by word and with `readall`; "Sum x squared stated." and "x
  squared" by word; "Drawn Blue entry square shown." and "Blue entry square" by word. The
  elements were then static text labelled with the attachment's words, so nothing said
  "image". With a new element for every read, as before, and each given the frame of its
  character, at `a46659e`, run 38356030625: a phrase with nothing in it and a step with no
  phrase in every one of those places, as on `main`.
  The section was the book's sixth and last in all of these sessions. `main` at `0128fa6`,
  merged in afterwards, has "What each line offers" as its sixth, so the section of entries
  is the seventh, with the same content and still opened by name. That merge changes
  nothing in a cell's code, and the sessions were not recorded again on it.
  Not heard: a picture, a formula or a hidden label inside a link in a cell; a part of a
  cell cut at a page's end; a formula without `alttext`, whose reading is generated; a rule
  or a picture in a table inside a cell; and an iPhone or iPad, where nothing changes. The
  Inspect Image action of a picture in a cell was chosen through VoiceOver afterwards, and
  the other cells heard in continuous scroll: see the record of Read Line in a table cell.
- On 2026-10-13 links in a table's cells were heard on a Mac: GitHub's hosted `xcode-27`
  runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points
  wide at 17 points, on the fixture's last section (`-SampleHref OPS/cells.xhtml`), with
  VoiceOver's link setting at Speak, at the fixed pause. Nobody listened, and no workstation
  was used. The section's first line, "Jumps inside a grid", was a heading in these runs. It
  is a paragraph now, so that the book's headings stay those of the earlier sections.
  The way into a cell was the same in every session. By word in the page's text: "grid."
  and then "Table row group". `in` there: "In Table row group 2 items text Plain first
  entry.". `right`: "text Before the worded jump after it, and then enough further wo".
  `in`: "In text Before the worded jump after it, and then".
  First main's reader with the new section, at `e3536cd`, in pages (run 38348189249) and in
  continuous scroll (run 38349867508), the same in both but for where one line of the first
  cell ends. `ax:links`: no child of the
  page's text, each row a group of two text areas, and each cell's link AppKit's, titled
  "worded jump", "￼", "￼", "￼ Entry jump with decoration" and "￼"; the element a cell gave
  as an attachment's printed neither a role nor a name. The cell with the link of words: by
  word "Before", "the", "worded", "jump", "after"; by line "Before the worded jump after it,
  and then", " it, and then" (the rest of the line, as after entering a page), "enough
  further words to carry this entry on to", back to the first, and "beginning of text";
  Find Next Link "worded jump hyperlink" and the hint; Control-Option-Space the page with
  "Link target reached" (`AXValueChanged` with `word1187` to `word1200`), and in continuous
  scroll the view at the target (`ENTRY`). The described picture: the cell was "text
  Described: "; by word "Described:", a step with no phrase, "end of text"; Find Next Link
  "￼ hyperlink", followed from there. The decoration alone: "Bare:", a step with no phrase,
  "end of text"; "￼ hyperlink", followed. Decoration and words: a step with no phrase,
  "Entry", "jump", "with", "decoration"; "￼ Entry jump with decoration hyperlink",
  followed. The hidden label: a step with no phrase, "Shown", "last", "entry."; Find Next
  Link said "text Shown last entry.", the cell again, and Control-Option-Space then did
  nothing. From the page's text Find Next Link said "Link not found". With VoiceOver on a
  cell of the row and not in it, Find Next Link went to the page's first line, and in
  continuous scroll to the book's first line, which the view then showed. `line` said
  nothing in the four cells where the cursor was on the cell's last word or past it.
  Then the reader's own elements in the cells, at `69917b1`, in pages (run 38352961195)
  and in continuous scroll (run 38352965104), again the same in both. `ax:links`: each
  cell's child and link titled "worded jump",
  "Described entry jump, image", "image", "Entry jump with decoration" and "Parked entry
  jump", a link element as the attachment of each picture and label, one without a name
  for the decoration before "Entry", and the five again as children of the page's text. The
  link of words as before, phrase for phrase. The described picture: the row was "In Table
  row group 2 items text Described:  hyperlink Described" and the cell "In text Described:
  hyperlink Described entry jump, image"; `line` on entering "Described:  hyperlink
  Described entry jump, image"; by word "Described:", "hyperlink Described entry jump,
  image", "end of text"; Find Next Link "Described entry jump, image hyperlink", and
  "actions available" before the hint. The decoration alone: by line "Bare:  hyperlink
  image"; by word "Bare:", "hyperlink image"; "image hyperlink". Decoration and words: by
  line "hyperlink  Entry jump", the cell's first; by word "hyperlink", "Entry", "jump",
  "with", "decoration"; "Entry jump with decoration hyperlink". The hidden label: by line
  "hyperlink Parked entry jump Shown last entry."; by word "hyperlink Parked entry jump",
  "Shown", "last", "entry."; "Parked entry jump hyperlink". Control-Option-Space after Find
  Next Link followed each of the five, and so it did from "hyperlink image", reached by
  word; in pages it also followed "worded jump" from the word "after" on that link's line.
  Each time the page with "Link target reached" came, or in continuous scroll the view
  went to it.
  From the page's text, in pages (run 38352309093, at `69917b1`) and in the last session
  of the scroll run: Find Next Link "worded jump hyperlink", "Described entry jump, image
  hyperlink", "image hyperlink", "Entry jump with decoration hyperlink", "Parked entry jump
  hyperlink" and "worded jump hyperlink" again, each with "You are currently on a
  hyperlink, inside of a text area", and Control-Option-Space from there the target. In
  pages, after the second of them `right` said "grid." and `line` "Shown words before the
  grid.": VoiceOver's place in the page's text had not moved, and Control-Option-Space
  then did nothing. With VoiceOver on a cell of the row, Find Next Link went to the page's
  first line as before, and a second one said "worded jump hyperlink".
  Once more at `75e28b6`, the same reader with main merged in up to `7b0cce2`, in one run
  of five sessions (38356059690), three in pages and two in continuous scroll: the described
  picture and the hidden label in their cells, and Find Next Link from the page's text in
  both flows. The same phrases, and each link followed.
  And at `87f032a`, with main merged in up to `7fa9231`, which has the elements a cell now
  keeps for its other attachments, and with the section's first line a paragraph, in one
  run of seven sessions (38369535055). In pages: the described picture, the decoration
  alone, decoration and words and the hidden label, each in its cell by line, by word, with
  Find Next Link and Control-Option-Space, and Find Next Link from the page's text. In
  continuous scroll: Find Next Link from the page's text, and the hidden label in its
  cell. The same phrases again, and each link followed. And once the page's headings had
  become its children beside its links, at `6d6c584` (run 38373248427, three sessions): Find
  Next Link from the page's text in pages and in continuous scroll, and the hidden label
  in its cell, as before.
  What did not work, heard once and left out, at `e54ad50` (run 38350087032): the cells'
  own elements as the page's children. From the page Find Next Link said "worded jump
  hyperlink" and then "Last link worded jump hyperlink" at every further press. VoiceOver
  goes on from a link through the children of that link's parent, which was the cell. In
  the same run `line` still said nothing after a cell's last word.
  The way in was found in two runs with `--advance-after 0.5` (38346989450 in pages,
  38346991372 in continuous scroll), which are no evidence. `ax:focus=0.2` there gave a
  cell keyboard focus, and `in` then entered the page's text.
  Not heard: listening; a workstation; two columns; a cell's link where a row goes on over
  a page's end, which the unit tests read; Read All in a cell with a link; link settings
  other than Speak; and a note's popover. What a cell says of a picture, a formula or a
  hidden label outside a link is in the entry before this one.
- On 2026-10-13 a link below the screen was reached with Find Next Link in continuous
  scroll on a Mac ([#425](https://github.com/vocaro/EPUBLib/issues/425);
  [links in an AppKit text view are children, not places](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-mac.md#links-in-an-appkit-text-view-are-children-not-places)):
  the hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a
  window 600 points wide at 17 points, with VoiceOver's link setting at Speak. Nobody
  listened. The sessions that are evidence are at the fixed pause and at `dcd0aa8`.
  Before, main's reader at `3f3ae69` (run 38423727356), in continuous scroll. From the
  top of the book `ax:links` gave the heading, "Verification link" and the heading below
  the screen, and three `nextlink` steps said "Verification link hyperlink", "Last link
  Verification link hyperlink" and nothing more. From two lines into the numbered
  paragraph `nextlink` said "Verification link hyperlink", the link above, and then "Last
  link" and its name. Opened at the pictures, four steps said the three links and "image
  hyperlink" again; at `OPS/offers.xhtml`, "Lone jump hyperlink", "Right cell jump
  hyperlink" and then the same two again; at `OPS/cells.xhtml`, where VoiceOver's first
  move after `in` took the view a line up and its cursor to "Below", a line of the
  section before, "Link not found" and nothing at five more steps.
  With the next link below the screen among the children (run 38421694695). `ax:links`
  from the top: four children, each `FOCUSABLE`, the last "Parked link to the target",
  which is at character 11,073 where `VISIBLE` ends at 10,963. `nextlink nextlink` gave
  "Verification link hyperlink" and the hint, and then `SELECTION 11073,0`, "words.",
  `AXLayoutChanged` and "hyperlink Parked link to the target" with the hint; `describe`
  "hyperlink is in the VoiceOver cursor"; `right` "hyperlink Parked link to the target";
  `right` "Shown"; `line` "hyperlink Parked link to the target Shown last words.".
  `activate` straight after the second `nextlink` moved the insertion point to 10,963,
  the heading "Link target reached": the link was followed.
  Sixteen `nextlink` steps from the top went through the book's fourteen links in order.
  Those with nothing on screen when VoiceOver moved to them were said after a word, role
  first: "words." and "hyperlink Parked link to the target"; "jump:" and "hyperlink
  image"; "Lone jump hyperlink", "before" and "hyperlink Lone jump"; "worded jump
  hyperlink", "grid." and "hyperlink worded jump", two sections on, in a table's cell;
  and "Reopened 1978 hyperlink", "Birch, 1934 table" and "hyperlink Reopened 1978", in a
  cell of a table of data, where what stands before the row is the table's row before
  it. Where the probe caught it, the name VoiceOver began with is there too. The others,
  on the screen the reader had gone to, were said as on a page: "Eighth cell link
  hyperlink", "Jump with decoration hyperlink", "Described jump, image hyperlink", "Right
  cell jump hyperlink", "Described entry jump, image hyperlink", "image hyperlink",
  "Entry jump with decoration hyperlink" and "Parked entry jump hyperlink". The fifteenth
  step said "Last link Reopened 1978 hyperlink", that link being the only one on screen,
  and the sixteenth nothing new. `ax:links` then gave it and the heading "A table longer
  than a page".
  A row below the screen, with the reader opened at `OPS/offers.xhtml`: `ax:links` gave
  the heading, "Lone jump", "Right cell jump", "worded jump", which is in a table two
  sections down, and the heading "Tables of data". Three `nextlink` steps said the first
  two as main does and then `SELECTION 15738,0`, the row, "grid." and "hyperlink worded
  jump"; `describe` "hyperlink is in the VoiceOver cursor"; `right` and `line` "Table row
  group"; `nextlink` from there "worded jump hyperlink", and `activate` followed it.
  With cursor tracking off (`tracking`, "Cursor Tracking Off"): "Verification link
  hyperlink", then "Parked link to the target hyperlink" with nothing before it,
  `SELECTION 11026,0` and "paragraph.", the view having been scrolled by VoiceOver and
  the insertion point following to the first line on screen; `right` said "Page" and
  `line` "Page boundary verification", the top of the book, where VoiceOver had last
  read. `tracking` again said "Cursor Tracking On".
  The link cases again, in pages (run 38421766784) and in continuous scroll (run
  38423525194). In pages, as before the change: on the first page `ax:links` the heading,
  the link and the heading on a later page; "Verification link hyperlink", "Last link
  Verification link hyperlink", and `activate` the page of `word1187`; by word
  "Verification", "link.", by line "Verification link. Image:  Blue verification square
  image .", and `activate` from "link." the same page. The hidden labels: "closing",
  "words.", "hyperlink Parked link to the target", "Shown", the line "hyperlink Parked
  link to the target Shown last words.", `nextlink` "Parked link to the target
  hyperlink", `describe` "hyperlink is in the VoiceOver cursor", and `activate` its
  target. The pictures: "image hyperlink", "Jump with decoration hyperlink", "Described
  jump, image hyperlink" and "image hyperlink" again, with `activate` its target; by word
  "Bare", "jump:", "hyperlink image", "hyperlink", "Jump", "with", "decoration",
  "hyperlink Described jump, image"; and `activate` on "hyperlink image", reached by
  word, the target. The links in cells: from the page the five in order, "worded jump
  hyperlink" again, and `activate` the target; inside a cell "Table row group", "In Table
  row group 2 items text Plain first entry.", "text Before the worded jump after it",
  the cell's line, "worded jump hyperlink" and `activate` the target. The move by heading
  from a link: "heading level 2 Link target reached", `line` "Link target reached",
  `right` "Link".
  In continuous scroll the same phrases by word, by line and inside a cell, and each
  `activate` put the insertion point on "Link target reached". What differs is where
  `nextlink` goes past the last link on screen. At the pictures the fourth step said
  "Lone jump hyperlink", "before" and "hyperlink Lone jump", two sections on, where main
  says "image hyperlink" again, and `activate` followed that link. At `OPS/cells.xhtml`,
  in the place where main said "Link not found", the first step gave `SELECTION
  15738,0`, "grid." and "hyperlink worded jump", the next four the other four links as
  on a page, and the sixth "Reopened 1978 hyperlink", "Birch, 1934 table" and "hyperlink
  Reopened 1978", which `activate` followed. From two lines into the numbered paragraph
  `nextlink` said "Verification link hyperlink", as main does, and `right` read on with
  "word0013": a link on screen is left as it is. The move by heading from a link said
  "word1200" and "heading level 2 Link target reached" as before, and `nextlink` from
  the heading's line "Parked link to the target hyperlink", by then on screen.
  How the reader came to act only for a link with nothing on screen was found in three
  runs at a pause of 3 seconds, which are no evidence. In 38414908587 (`7bbe60c`) every
  link's element put the insertion point on its link when VoiceOver focused it, which it
  did at every `nextlink`. VoiceOver then said the word beside the new place about 60 ms
  after it began the link's name: "word." and the hint with no "Verification link
  hyperlink", "grid." and the hint for a cell's link, "hyperlink image", the item before,
  in place of "Jump with decoration hyperlink", and nothing at all at one step. Reading
  by word and by line was as on main. In 38417225645 (`fe36bcc`) and 38419320983
  (`9797f6a`) a launch argument chose among ways to move VoiceOver's place without that
  word. The text answering a new insertion point with no notification: `right` after
  "Verification link hyperlink" said "word0001", where VoiceOver had last read, and after
  the link below the screen, said by its name alone, "word0003", with the view taken back
  to the top. The same with a layout change that names the text: "Verification link
  hyperlink", "hyperlink Verification link", and `right` "word0001". A notification of
  the reader's own that the selection changed, bare, with `AXTextSelectionChangedFocus`
  or with `AXTextStateSync`: all three moved VoiceOver's place, `right` saying
  "Verification" and "link.", and all three said the word, "Verification" over the name
  in continuous scroll and "Verification link hyperlink" and then "Verification" in
  pages. With the reader acting only for a link with nothing on screen, as built:
  "Verification link hyperlink", `right` "word0001", and then, from the text two words
  on, `nextlink` went to the link below with "words." and "hyperlink Parked link to the
  target". Main's reader at `229a612` said "Link not found" at that same step (run
  38419459166): having been on the link's element, VoiceOver looked for a link after it.
  Not heard: listening; a workstation; two columns, which continuous scroll has not; a
  larger text size; a book whose next link is many screens down, where the place TextKit
  gives a line not yet laid out is an estimate; a link in a row that is taller than the
  screen; Find Previous Link, which goes forward on this macOS; and link settings other
  than Speak.
- On 2026-10-12 and 13 pages were turned under VoiceOver's cursor before and after the
  reader sent the cursor to the page shown
  ([#449](https://github.com/vocaro/EPUBLib/issues/449);
  [the rotor keeps its place only on the same element object](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#the-rotor-keeps-its-place-only-on-the-same-element-object)).
  The device is the physical iPad Air 13-inch
  (M3) of the sessions above (iPadOS 27.2, 1024 × 1366, upright, 17 points, Xcode 27.0),
  through XCTest's VoiceOver service, on the book's first section. Nobody listened.
  Before, at `707e776`. With the cursor on "word0001 …", the first numbered line of the
  first page, `flick=down` read "Next Page" and a double tap performed it: the page showed
  `word0294`–`word0654`. The screenshot shows VoiceOver's cursor drawn where the old line
  had stood, across the eighth and ninth lines of the new page, and three moves forward
  each read "VoiceOver Page Boundary Verification", the book's title under the page. With
  the cursor then put on "word0450 …" in the middle of that page (`point=0.5:0.5`), Next
  Page showed `word0655`–`word1012` with the cursor drawn at the same place, now over
  "word0818 …", and the three moves read "word0850 …", "word0842 …" and "word0850 …":
  four lines below the cursor, the line above that, and the first again. From "word0818
  …", Previous Page showed `word0294`–`word0654` with the cursor over "word0450 …", and
  the moves read "word0474 …", "word0466 …", "word0474 …". Those two pages are full of
  lines of eight and nine words. The reader answered for an element of the page before by
  its characters counted from the top of its own page (`index(ofAccessibilityElement:)`),
  and on such pages those are the characters of a line of the page turned to. A unit test
  now holds the answer to the line's place in the book.
  Before again, at `7fa9231` with the probe's `listen` step, the `main` the change was
  last merged with. VoiceOver said nothing by itself after either turn. From "word0001 …"
  the three moves read "word0573 …", "word0565 …", "word0573 …", near the foot of the page
  that begins at `word0294`, where the first session had read the title; from "word0450
  …", "word0939 …", "word0931 …", "word0939 …". The line it came to was not the same from
  one session to the next, and was the page's first in none. With Previous Page chosen
  and performed from "word0818 …", a second double tap with no flick before it turned the
  page again, to `word0001`–`word0293`: on the line left behind the rotor stayed where it
  was.
  A page turned by the control strip's button needed no change. With the cursor taken
  from a line to the button (`activate=Next Page`), VoiceOver stayed on "Next Page Button",
  and moving forward read the strip's eight other controls and then "word0294 …",
  "word0302 …", "word0310 …", "word0319 …": the new page from its first line. After
  Previous Page it said "Previous Page dimmed", and moving forward read the controls again
  and "Page boundary verification Heading".
  After, at `7466dea`, the same steps with `listen=4` after each double tap. From "word0001
  …", Next Page: VoiceOver read "word0294 word0295 … word0301" by itself, the screenshot
  shows its cursor on that line, the first of the page, and the three moves read "word0302
  …", "word0310 …", "word0319 …". From "word0450 …", Next Page: it read "word0655 …", and
  the moves "word0663 …", "word0671 …", "word0680 …". From "word0818 …", Previous Page: it
  read "word0294 …", and the moves "word0302 …", "word0310 …", "word0319 …". After a link:
  with the cursor on "Verification link", a double tap showed the book's last page,
  `word1013`–`word1200`, and VoiceOver read "Link target reached Heading" by itself, the
  line of the link's target, below the twenty-one lines of words that begin that page; the
  next moves read "This is the end of the numbered paragraph." and the book's title. A
  turn by the control strip's button read as it had: VoiceOver stayed on "Next Page
  Button", moving forward read the eight controls and then "word0294 …", "word0302 …",
  "word0310 …", "word0319 …", and after Previous Page "Previous Page dimmed", the controls
  and "Page boundary verification Heading". On its side (1366 × 1024), where the first
  spread shows `word0001`–`word0147` beside `word0148`–`word0350`: with the cursor on
  "word0232 …" in the right-hand page, Next Page showed `word0351`–`word0553` beside
  `word0554`–`word0756`, VoiceOver read "word0351 …" by itself, the first line of the
  left-hand page, and the moves read "word0358 …", "word0365 …", "word0372 …". A last
  session at `a38fa29`, after `main`'s change to the scroll bar of continuous scroll had
  been merged into the same file, read the same, upright: "word0294 …" after Next Page
  from "word0001 …" and the three lines after it; and after Previous Page from "word0450
  …", "Page boundary verification Heading", the first line of the first page, then "Read
  the numbered words across two consecutive pages. The next page must resume at the",
  "next numbered word." and "Verification link Link".
  What the change costs was seen in these sessions. The cursor is on a new item after a
  turn, and VoiceOver's rotor is at its default there: with Previous Page chosen and
  performed from "word0818 …", a second double tap, with no flick before it, read the
  first line again and left `word0294`–`word0654` on screen, where before the change it
  had turned the page again. A listener turning several pages from the text now flicks
  down before each double tap. On the control strip's button the cursor stays on the
  button, and double taps turn page after page as they did.
  The [simulator lane](#simulators) read the same change another way, since a simulator's
  VoiceOver performs no action: the cursor is put on a line, and `doubletap=Next Page`
  lands one plain touch on the control strip's button while the cursor stays on the line.
  That is a page the host turns under the cursor, which the reader treats as it does a
  line's own turn. iPhone 17 Pro simulator, iOS 27.0, 402 × 874, 17 points. Before, at
  `0128fa6` with the probe's `listen` step: from "word0001 …" VoiceOver said nothing, and
  the moves read "VoiceOver Page Boundary Verification", "word0061 …", "word0065 …", on a
  page that begins at `word0017`; from "word0025 …", the third line of that page, the
  moves read "word0093 …", "word0089 …", "word0093 …" on the page that begins at
  `word0081`; and after Previous Page "word0029 …", "word0025 …", "word0029 …". After, at
  `7466dea`: VoiceOver read "word0017 word0018 word0019 word0020" by itself, the first line
  of the page, and the moves read "word0021 …", "word0025 …", "word0029 …"; from "word0025
  …" it read "word0081 …" and the moves "word0085 …", "word0089 …", "word0093 …"; and
  after Previous Page "word0017 …" and the same three.
  The order of the two things VoiceOver's scroll posts was tried there too, in a build
  with a switch for what is posted (not in the branch). The page's number and then the
  line: "Page 2", then "word0017 word0018 word0019 word0020", and the moves read on from
  the second line. The line and then the number: the line alone, and no "Page 2". The
  number alone, which is all the scroll posted before: "Page 2", and VoiceOver's cursor
  stayed at its place on the screen, so that from the third line of one page the next
  move read the fourth line of the next, "word0093 …", and not its first.
  Not established: VoiceOver's three-finger scroll itself, which XCTest cannot perform
  ([#70](https://github.com/vocaro/EPUBLib/issues/70)), before the change or after it; a
  physical iPhone; a page turned by a key with the cursor in the text; and Switch Control
  or any other assistive technology that keeps a cursor. VoiceOver was read back as off
  after every device session.
- On 2026-10-13 VoiceOver's rotor was kept on a line's page action across the turn. The
  change recorded above sends the cursor to a new item, where the rotor is at its default.
  Now the item under the cursor becomes the first line of the page shown and is the item
  posted with the layout change. The device is the physical iPad Air 13-inch (M3) of the
  sessions above (iPadOS 27.2, 1024 × 1366, upright, 17 points, Xcode 27.0), through
  XCTest's VoiceOver service. Nobody listened.
  The steps, on the book's first section: `point=0.5:0.5`, which put the cursor on
  "word0089 …" on the first page; `flick=down`, which read "Next Page"; a double tap;
  `listen=4`; a second double tap with no flick before it; `listen=3`; `visible`; and
  `forward=3`.
  Before, on `main` at `593b907`. After the first double tap VoiceOver read "word0294
  word0295 … word0301" by itself. After the second it read that line again and
  `word0294`–`word0654` was still on screen: the page had not turned. The moves read
  "word0302 …", "word0310 …", "word0319 …".
  After, at `0ea1f28`, the change on that `main`. After the first double tap it read
  "word0294 …" by itself, and the screenshot shows its cursor on that line. After the
  second it read "word0655 word0656 … word0662", the first line of the page after, the
  screenshot shows its cursor there, and `word0655`–`word1012` was on screen. The moves
  read "word0663 …", "word0671 …", "word0680 …".
  Back again, in a session of its own: two double taps forward as above, `flick=down` once
  more, which read "Previous Page", and three double taps. The first read "word0294 …"
  and the second "Page boundary verification Heading", the first page's first item, with
  `word0001`–`word0293` on screen. At the third nothing on screen changed in two seconds,
  and VoiceOver said the heading again: the book has no page before its first.
  On its side (1366 × 1024), where the first spread shows `word0001`–`word0147` beside
  `word0148`–`word0350`: with the cursor on "word0232 …" in the right-hand page, Next Page
  read "word0351 …" by itself, the first line of the left-hand page of the next spread. A
  second double tap read "word0757 …", the first line of the spread after that, which
  shows `word0757`–`word0959` beside `word0960`–`word1163`, and the moves read "word0764
  …", "word0771 …", "word0778 …". The item had been a line of the right-hand column and
  was then one of the left.
  What the item is after it has become another line was read in three sections. In
  "Scenes set apart" (`OPS/scenes.xhtml`), with the cursor on "First scene ends." and Next
  Page chosen, three double taps in a row read "Separator", the rule alone on its page,
  then "Last words of the scenes.", then "What each line offers Heading", the first item of
  the next section. Stepping through the rotor there read "Previous Page", "Activate
  Default" and "Next Page", and two moves forward read "Plain words above." and "Words
  before". In "What each line offers" (`OPS/offers.xhtml`) Next Page was chosen and
  performed from the link "Lone jump", from the picture "Square with words" and from the
  row "Left cell Right cell jump", each in a session of its own. Each time VoiceOver read
  "Below line 18." by itself, and the rotor on that item offered "Previous Page", "Activate
  Default", "Next Page" and "Previous Page" again: no Inspect Image after the picture, and
  no Select Table Text or Follow Table Link after the row. After the link, a double tap on
  "Activate Default" left "Below line 18." under the cursor, and Previous Page chosen and
  performed from it then read "What each line offers Heading": the item that had been a
  link followed nothing. Each kind still did its own on the page come back to. Three
  moves forward from the heading reached "Lone jump Link", and a double tap read "Link
  target reached Heading", the line of the link's target in the first section. On "Square
  with words" the rotor read "Next Page", "Previous Page" and "Inspect Image: Square with
  words", and a double tap put VoiceOver on "Zoom Out Button", in the inspector. On the
  row it read "Next Page", "Previous Page" and "Select Table Text: Left cell", and a
  double tap said "Select Table Text: Left cell" with nothing on screen changed
  ([#450](https://github.com/vocaro/EPUBLib/issues/450) has the selection that is not
  seen).
  A data table's cell is where the rotor still starts again, since a cell's item becomes
  no line and no line's item a cell. In "Tables of data" (`OPS/grids.xhtml`), with the
  cursor on "Twelve metres Row 2 Column 3" and Next Page chosen, a double tap read "Line
  06 after the grids." by itself, and a second double tap read that line again: the page
  had not turned. With Next Page chosen anew on that line, three double taps read "Line
  32 after the grids.", then "A table longer than a page Heading", then "Entry 27 Row 28
  Column 1 Table start 41 rows 3 columns", the first cell of the page after: from a line
  the turns went on, and the cell that the last one came to was a new item.
  A turn by the control strip's button read as it had. With the cursor taken from a line
  to the button (`activate=Next Page`), VoiceOver stayed on "Next Page Button", and moving
  forward read the strip's eight other controls and then "word0294 …", "word0302 …",
  "word0310 …", "word0319 …". After Previous Page it said "Previous Page dimmed", and
  moving forward read the controls and "Page boundary verification Heading".
  Three ways of telling VoiceOver were tried before the change was settled, in a build
  with a launch argument for which to use (not in the branch), on the same steps and the
  same iPad. That build was the change as first written, on `19a3f7a`, before the data
  tables of `593b907`. With the item under the cursor made the new line and posted with
  the layout change, which is what the reader now does: as above. With the item made the
  new line and the layout change posted with no item: after each double tap "Next Page"
  was still the phrase standing and VoiceOver said nothing more, the screenshot shows
  its cursor on the first line, the second double tap turned the page again, and the
  moves read "word0663 …", "word0671 …", "word0680 …". With that and the line's words
  posted as an announcement: VoiceOver said the words after each double tap, in a phrase
  recorded as far as the first letter of the line's last word, and the second double tap
  turned the page again. An announcement is a string the reader speaks, though, and not
  the item read: of an item VoiceOver also says what it is, as "Heading" above.
  A new item for the line is the before of this record.
  The [simulator lane](#simulators) read the same three with the page turned under the
  cursor by a plain touch on the control strip's button, since a simulator's VoiceOver
  performs no action. iPhone 17 Pro simulator, iOS 27.0, 402 × 874, 17 points, the cursor
  on "Page boundary verification", the heading that opens the first page. With the item
  posted: VoiceOver read "word0017 word0018 word0019 word0020" by itself, without
  "Heading", and the moves read "word0021 …", "word0025 …", "word0029 …". With no item
  posted it said nothing, and the moves were the same three. With the announcement it
  said the line. With the page's number posted first and then the item, the order
  VoiceOver's scroll posts: "Page 2", then "word0017 word0018 word0019 word0020", as it
  was when the line was a new item.
  VoiceOver was read back as off after every device session. In eight of them a phrase
  that is not the test book's or the sample's was recorded when VoiceOver came on, the
  same number of characters each time, and two more at the rotations of the session on
  the iPad's side. None was read, those sessions' logs and result bundles were deleted,
  and none of their screenshots was opened: the screenshots cited are of sessions on the
  first section that recorded no such phrase
  ([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).
  Not established: a physical iPhone; VoiceOver's three-finger scroll itself
  ([#70](https://github.com/vocaro/EPUBLib/issues/70)); a page turned by a key with the
  cursor in the text; an item that becomes a picture, a link or a table row on a device,
  which unit tests hold to the answers of a new item; and Switch Control or any other
  assistive technology that keeps a cursor.
- On 2026-10-13 the item under the cursor was made to go with the page into a data table
  and out of one. The change recorded above left a data table's cell as it was: from a
  cell, or onto a page that opens with one, the reader posted a new item and the rotor
  started again. A line and a cell are now one class of item, a cell to whoever asks it
  only while it is one, and the item VoiceOver holds becomes the cell that opens the page
  shown, or the line. From a cell to a cell the reader still posts a new item, for the
  reason found below.
  A physical iPad Air 13-inch (M3) read it that morning: iPadOS 27.2, 1024 × 1366, upright,
  17 points unless said, Xcode 27.0, VoiceOver through XCTest's service, nobody listening. A
  device is needed for the point of the change, which a simulator cannot show: that a double
  tap performs the action chosen in the rotor, so that a second double tap turns the next
  page. Before is `d9e4d25`, `main` with the change recorded above and nothing of this one,
  and after is `ad3ded5`, this change with that `main` merged into it. Each step list was a
  session of its own on each, between 08:06 and 08:26 PDT. The cursor was put on an item,
  Next Page chosen in the rotor (`flick=down` read "Next Page" in every session) and
  performed twice with no flick between: `doubletap=VoiceOver Page`, `listen=4`,
  `screenshot`, `doubletap=VoiceOver Page`, `listen=3`, `screenshot`, then `forward=3`.
  From a cell to a line, in "Tables of data" (`OPS/grids.xhtml`), from "Twelve metres Row 2
  Column 3". Before and after alike the first double tap read "Line 06 after the grids."
  Before, the second read that line again and the moves read "Line 07 after the grids.",
  "Line 08 …" and "Line 09 …": the page had not turned. After, the second read "Line 32
  after the grids.", the first line of the page after, and the moves read "Line 33 …", "Line
  34 …" and "Line 35 …". The screenshots after show VoiceOver's cursor on "Line 06 after the
  grids." and then on "Line 32 after the grids.", each at the top of its page; before, on
  "Line 06 …" both times.
  From a line to a cell, in "A table longer than a page" (`OPS/ledger.xhtml`), from the
  heading. Before and after alike the first double tap read "Entry 27 Row 28 Column 1 Table
  start 41 rows 3 columns", the cell that opens the next page. Before, the second changed
  nothing on screen and read the cell again, and the moves read "Item Item 27 Column 2",
  "Sum Sum 27 Column 3" and "Entry Entry 28 Row 29 Column 1". After, it turned the page from
  that cell: VoiceOver read "Line 14 after the ledger.", and the moves "Line 15 …", "Line 16
  …" and "Line 17 …", with no row or column. One item had been a heading, a cell and a line,
  and the action chosen on the heading was performed from each. The screenshots after show
  the cursor on the cell "Entry 27", the table's first on that page, and then on "Line 14
  after the ledger."; before, on "Entry 27" both times.
  The cells around the item that had become a cell, after one turn from the heading
  (`forward=3,backward=3` in place of the second double tap). Before and after alike: "Item
  Item 27 Column 2", "Sum Sum 27 Column 3", "Entry Entry 28 Row 29 Column 1", and back "Sum
  Sum 27 Row 28 Column 3", "Item Item 27 Column 2", "Entry Entry 27 Column 1 Table start 41
  rows 3 columns". The item that had been a heading is the table's first cell from either
  side, as a new item for that cell is.
  Into the table and back out of it, by Previous Page: after the same turn from the heading,
  `flick=down`, a double tap, `listen=4`, `screenshot`, a second double tap, `listen=3`,
  `screenshot`, `forward=2`. The flick read "Next Page" before and "Previous Page" after,
  the action after the one chosen: on the new item the rotor had started again, and on the
  item that had become a cell it had kept its place. After, the double tap read "A table
  longer than a page Heading", the second read "Line 32 after the grids.", the first line of
  the last page of the section before, and the moves read "Line 33 …" and "Line 34 …"; the
  screenshots show the cursor on the heading and then on "Line 32 after the grids.". One
  item had been a heading, a cell, the heading again and a line of another section, and
  Previous Page was performed from it as a cell and as the heading. Before, the double tap
  performed the Next Page the flick had come to and read "Line 14 after the ledger.", and
  the second read that line again.
  From a cell to a cell, the same section at 28 points, from "Entry 03 Row 4 Column 1".
  Before and after are the same, since the reader does the same: "Entry 15 Row 16 Column 1
  Table start 41 rows 3 columns" after the first double tap and again after the second,
  which turned nothing, and the moves "Item Item 15 Column 2", "Sum Sum 15 Column 3" and
  "Entry Entry 16 Row 17 Column 1". The screenshots show the cursor on "Entry 15" both
  times.
  The change as it stood before `main` was merged into it, `f7cc4d5`, had read the same as
  `ad3ded5` in the first two step lists a few minutes earlier, and the change recorded above
  at its own commit, `0ea1f28`, the same as `d9e4d25` in the first.
  VoiceOver was read back as off after every one of the fourteen sessions. In three of them
  53 characters that are not the test book's or the sample's were recorded when VoiceOver
  came on, as in the sessions recorded above. None was read, those sessions' logs and result
  bundles were deleted and none of their screenshots was opened. One more bundle was deleted
  for a first phrase that was empty, which is nobody's words; that session, from a cell to a
  line at `ad3ded5`, was run again for its screenshots and read the same. The screenshots
  cited are of sessions that recorded no such phrase.
  The iPad could not be used before 07:53 PDT. From 04:15 it ended every session before its
  first step with "Timed out while enabling automation mode", twelve sessions of this branch
  and another: its authorization for UI automation, given at 20:13 the evening before, lasts
  eight hours, and it was asking its owner for the passcode
  ([Physical iPhone and iPad](#physical-iphone-and-ipad)).
  The [simulator lane](#simulators) had read the change in those hours, at the commits it
  then had: iPad Air 13-inch (M4) simulator, iOS 27.0, 1024 × 1366, upright, Xcode 27.0,
  through XCTest's VoiceOver service. A simulator's VoiceOver performs no action, so each
  page was turned under the cursor by the plain touch that `doubletap=Next Page` arrives as
  on the control strip's button, and the flick after the turn says where the rotor is:
  "Previous Page", the action after the one chosen, where it kept its place, and "Next Page"
  where it started anew. Before is `5765261`, the change recorded above, and after is
  `8a6c0f9`; each step list was a session of its own on each. Its pages are not the iPad's:
  the page after the heading of "A table longer than a page" opens with "Entry 28" there and
  with "Entry 27" on the iPad.
  From a cell to a line, in "Tables of data" (`OPS/grids.xhtml`) at 17 points:
  `touch=Twelve metres`, `flick=down`, the turn, `listen=4`, `screenshot`, `flick=down`,
  `forward=3`. Before and after alike the touch read "Twelve metres Row 2 Column 3", the
  first flick "Next Page", VoiceOver read "Line 06 after the grids." by itself, and the
  moves read "Line 07 after the grids.", "Line 08 …" and "Line 09 …", with no row or
  column. The second flick read "Next Page" before and "Previous Page" after, and the
  screenshot after shows VoiceOver's cursor on "Line 06 after the grids.".
  From a line to a cell, in "A table longer than a page" (`OPS/ledger.xhtml`) at 17
  points, from the heading, with `backward=3` after the moves forward. Before and after
  alike VoiceOver read "Entry 28 Row 29 Column 1 Table start 41 rows 3 columns" by
  itself; forward, "Item Item 28 Column 2", "Sum Sum 28 Column 3", "Entry Entry 29 Row 30
  Column 1"; and back, "Sum Sum 28 Row 29 Column 3", "Item Item 28 Column 2", "Entry Entry
  28 Column 1 Table start 41 rows 3 columns". The item that had been a heading is the
  table's first cell from either side. The flick read "Next Page" before and "Previous
  Page" after, and the screenshot after shows VoiceOver's cursor on the cell "Entry 28".
  Into the table and back out of it, by Previous Page: after the same turn, a plain touch
  on the strip's Previous Page (`doubletap=Previous Page`), `listen=4`, `screenshot`,
  `flick=down`, `forward=2`. Before and after alike VoiceOver read "A table longer than a
  page Heading", and the moves read "Words before the ledger." and "Entry Column header
  Row 1 Column 1 Table start 41 rows 3 columns". The flick read "Next Page" before and
  "Previous Page" after, and the screenshot after shows VoiceOver's cursor on the
  heading: one item had been a heading, a cell and the heading again, and the rotor was
  where it had been put.
  From a cell to a cell, the same section at 28 points, from "Entry 03 Row 4 Column 1",
  with a second turn and flick. Before and after are the same, since the reader does the
  same: "Entry 15 Row 16 Column 1 Table start 41 rows 3 columns" and the flick "Next
  Page", then "Entry 34 Row 35 Column 1 Table start 41 rows 3 columns" and "Next Page"
  again, and the moves "Item Item 34 Column 2", "Sum Sum 34 Column 3", "Entry Entry 35
  Row 36 Column 1".
  Why a cell does not become a cell was read on a build of the change as first written,
  `af2324e`, with launch arguments for which item is posted and how (not in the branch),
  on the same steps. With the item VoiceOver held made the new cell: "Entry 15" and the
  flick "Previous Page", then "Entry 34" and "Select Cell Text". The rotor kept its place
  across both turns, the new cell's own action was offered, and the moves read as above,
  but VoiceOver said the cell's words alone. It says a cell's row and column, and "Table
  start", of an item its cursor comes to, and of the item already under its cursor only
  when that item was no cell before, as the line above was. Five more ways of telling it,
  each with the item it held. A screen change in place of the layout change: it said
  nothing after either turn, the rotor was kept, and the next move read "Item Item 34 Row
  35 Column 2", with the row it had not been told. The table's item in place of the
  cell's, the table's own item kept from the page before, and a layout change with no
  item before the one with it: "Entry 15" and "Entry 34" alone each time, the rotor
  kept. "Row 16, Column 1" as the item's value: "Entry 15 Row 16, Column 1" and "Entry 34
  Row 35, Column 1", the rotor kept. The same words as a queued announcement: "Row 16,
  Column 1" and then "Entry 15". The last two are the reader's words and not VoiceOver's,
  in one language, and would be said twice by a VoiceOver that said its own; they are
  not done.
  A page of lines reads as it did. In "Tables of data", from "Line 03 after the grids.":
  "Line 06 after the grids." and the flick "Previous Page". On an iPhone 17 Pro simulator
  (402 × 874) on the book's first section, with the cursor on the heading
  (`point=0.5:0.5,doubletap=Next Page,listen=4,forward=3`), three sessions at `8a6c0f9`:
  the moves read "word0021 … Actions available", "word0025 …", "word0029 …" in each, and
  VoiceOver read "word0017 word0018 word0019 word0020" by itself in two of them. In the
  first, at a load average over 400, it said nothing after the turn.
  Not established: a physical iPhone; a cell that becomes a line across an iPad's spread,
  which unit tests hold to the column it is then in; a cell whose page turns to a cell of
  another table, which the reader treats as it does a cell of the same one; and Switch
  Control or any other assistive technology that keeps a cursor.
- On 2026-10-13 the three sections of tables were read on a Mac before and after a table of
  data was given to VoiceOver as a table
  ([on the Mac VoiceOver meets a table only at an attachment character](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#on-the-mac-voiceover-meets-a-table-only-at-an-attachment-character);
  [a cell that names its own header cells makes Mac VoiceOver quit](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-cell-that-names-its-own-header-cells-makes-mac-voiceover-quit)):
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), a window 600 points wide at 17
  points, a fixed pause of four seconds, the same steps both times. Before at `593b907`,
  which is `main`: runs 38383252896 (pages) and 38388226307 (continuous scroll). After at
  `66b2f8b`: runs 38391040735 and 38391133441. Nobody listened.
  The tables of data, pages. Before, by line and by word, each row said "Table row group"
  and none of its words; `in` on the second row "In Table row group 3 items text Alder",
  then "text 1901", "text Twelve metres"; Control-Option-Down stayed on "text Twelve
  metres", Control-Option-C read the character "T" and Control-Option-R said nothing. The
  Actions menu inside a cell was the text area's "show menu", which opened a menu of
  thirteen items. After: "Station, Opened, Depth table", "Alder, 1901, Twelve metres
  table", "Birch, 1934 table", "Cedar, Reopened 1978, Forty metres table", and the same
  back up. `in` on Alder's: "In Alder, 1901, Twelve metres table Station Alder", "Opened
  1901", "Depth Twelve metres", down "Birch empty cell", Control-Option-C "Depth",
  Control-Option-R "Birch". By word "Stations", "on", "the", "branch" and then each row as
  by line; `in` on Birch's, `right` "Opened 1934", `in` "In text 1934", `right` "1934",
  `out` "Out of text"; `actions` "Actions menu 1 item", "Select Cell Text", and chosen,
  "Select Cell Text 1934 cell". On Cedar's row, at "Opened Reopened 1978", "Actions menu 2
  items", "Select Cell Text", "Follow Link: Reopened 1978", and chosen, the page changed to
  the one with "Link target reached" (`word1187` first). Before, the same keys chose "show
  menu" there.
  The second page, with the table whose cells span, the table marked as layout and the
  first row of the ruled one. After: "Service, Hours table", "Leaves, Arrives table"; `in`
  there "In Leaves, Arrives table Hours, Leaves Leaves", `right` "Hours, Arrives Arrives",
  `right` "Service Express", down "Stopper", down again "Stopper column 1, row 4"; `out`,
  and by line "Express, Nine, Noon table", "Stopper, Ten, Three table", "Nothing on Sunday
  table", "Words before the layout.", "Table row group", "Words after the layout.". Before:
  "Table row group" at each row, `in` on the second "In Table row group 2 items text
  Leaves", `right` "text Arrives", and Control-Option-Down stayed there.
  The long table, pages. After: "Entry, Item, Sum table", "Entry 01, Item 01, Sum 01
  table", `in` "In Entry 01, Item 01, Sum 01 table Entry Entry 01", "Item Item 01", `out`.
  Then a page turn by the host's button, with VoiceOver's cursor on the table it had left:
  after, "text Entry 08, Item 08, Sum 08 table", VoiceOver on the text area and not in it,
  so the steps that followed read the first row from outside; before, "VoiceOver
  Verification window Open EPUB… button", VoiceOver out of the text altogether. The tall
  row: its first page says "Clause, Wording table" and the second, after, the page's words
  and then `in` "In t0001 t0002 …", `in` again "In text t0001 …", `right` "t0001"; before,
  "Table row group" and "In Table row group text t0001 …".
  Continuous scroll. Before, by line, "Table row group" at the rows on screen and a row's
  words and "image" at one off it ("Entry 39 Item 39 Sum 39 image", "Short clause Short
  wording image"); `in` gave a row's text areas, and Control-Option-Down did not move.
  After, by line through the section of tables of data, each row by its words and "table"
  down to "Nothing on Sunday table", "Words before the layout." and "Table row group";
  `in` on Birch's "In Birch, 1934 table Station Birch", "Opened 1934", "Depth empty cell",
  down "Cedar Forty metres", "Depth", "Cedar". In the long table, from "Words after the
  ledger." three lines up to "Entry 38, Item 38, Sum 38 table"; `in` "Entry Entry 38",
  "Item Item 38", up "Item 37", down "Item 38", "Item 39", "Item 40", and at the end "Item
  40 column 2, row 41", the header row thirty-eight rows above the screen throughout. From the header row, twenty-eight moves
  down read "Entry 01" to "Entry 28", each once, with the view following
  (`AXValueChanged` from the reader as it went), and `out` brought the view back to the
  header row's line. The tall row is one line there, "Tall clause, t0001 t0002 …", and its
  cell "Wording t0001 …".
  How the shape was found, on the same runner. What stands at a row's character was tried
  as the row itself, as one table for every row, as a table at the first row alone, and as
  a table for each row (runs 38363647251, 38368626343, 38370804197, 38372891705);
  [the native viewer](native-viewer.md) ("Data tables", "On Mac") has what VoiceOver did
  with each. Through `ax:tables` a client of the accessibility API was given, for the table
  at each row, `AXRows`, `AXVisibleRows`, `AXSelectedRows`, `AXColumns`, `AXVisibleCells`,
  `AXColumnHeaderUIElements`, `AXRowHeaderUIElements`, `AXRowCount` and `AXColumnCount`, and
  for each cell its `AXRowIndexRange` and `AXColumnIndexRange`.
  VoiceOver quit six times while a cell named its own header cells: once at four seconds a
  key in continuous scroll (run 38368626343, before reports were collected), once at four
  seconds in pages (run 38379235409), in each of three sessions at two seconds (run
  38381039862), and in one of five at two seconds once those header cells were elements of
  their own (run 38383168370). The five reports macOS wrote have one backtrace, an
  exception from `__CFStringCheckAndReplace` in `-[SCRCell columnHeaderDescription]` under
  `-[SCRTable _columnHeaderDescriptionForCellElement:headerIndex:]`. With the headers given
  by the table for each column and row it did not quit: seventeen sessions at two or three
  seconds a key (runs 38386166417, 38388118801, 38389952858 and, on the code as it is,
  38392704337), each of about twenty moves among cells with Control-Option-C or
  Control-Option-R after each, and the ten sessions above. In those, a header that was a
  cell with a title or a label and nothing in it was not said ("column 2 of 3 Nine"), and
  one that was a static text, a button with a title or a cell holding a static text was
  ("Hours, Leaves Nine"). The reader keeps the static text.
  Not heard: anyone listening, or any Mac but the runner; a spread of two columns; a table
  in a note's popover; Inspect Image chosen from a cell; a cell's `headers` attribute;
  VoiceOver in another language or with its verbosity changed; Read All through a table;
  and what Books says of the same tables on a Mac
  ([#484](https://github.com/vocaro/EPUBLib/issues/484)). What Safari says of them, and
  Control-Option-C and Control-Option-R pressed twice on the shape that was kept, are in
  the next entry. The page turn that leaves VoiceOver out of the text is
  [#485](https://github.com/vocaro/EPUBLib/issues/485).
- Later on 2026-10-13 the same tables were heard in Safari on a Mac and set beside the
  reader
  ([Safari reads tables with web-page speech](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#safari-reads-tables-with-web-page-speech)):
  the section of tables of data and the long table, each opened as a file in Safari
  27.0.1 (`22625.1.29.11.28`) on the same hosted runner (image `20261006.0244.1`, macOS
  27.0.1 `26A434`, Xcode 27.0), a window 600 points wide, a fixed pause of four seconds.
  The reader was `main` at `3f3ae69`, which has
  [#476](https://github.com/vocaro/EPUBLib/pull/476), built at `e8032b1` with this harness,
  in pages, 600 wide at 17 points, given the same keys from the table's first cell. Safari:
  run 38416799829 (four sessions on the tables of data) and run 38419267112 (the long
  table, and three sessions at two seconds a key). The reader: run 38422077936. The same
  keys had gone to #476's branch before it merged (`f9eb33b`, runs 38419223106 and
  38416874099), and what it said was the same but in the two places marked. How Safari is
  driven was found in run 38414486982, with the next key half a second after a phrase;
  [Safari on Mac](#safari-on-mac) has it. Nobody listened, and the runner's screenshots
  show Safari's page white.
  A phrase is cut at 64 characters, shown by "…". Safari reads on by VoiceOver's next item
  (Control-Option-Right) and the reader by line (Control-Option-Down); every other key is
  the same in both. In the reader "going in" is Control-Option-Shift-Down on a row's line,
  and in Safari Control-Option-Command-T to the table and then Control-Option-Shift-Down,
  though reading on by item enters a table's cells without it.

  | Move | Safari | The reader |
  | --- | --- | --- |
  | Reading on: the caption and the first table | "Stations on the branch table 3 columns, 4 rows" | "Stations on the branch", "Station, Opened, Depth table" |
  | Its header row | "Station column 1 of 3", "Opened column 2 of 3", "Depth column 3 of 3" | the line above |
  | Its second row | "row 2 of 4 Station Alder column 1 of 3", "Opened 1901 column 2 of 3", "Depth Twelve metres column 3 of 3" | "Alder, 1901, Twelve metres table" |
  | The row with an empty cell | "row 3 of 4 Station Birch column 1 of 3", "Opened 1934 column 2 of 3", "Depth blank column 3 of 3" | "Birch, 1934 table" |
  | The row with a link | "row 4 of 4 Station Cedar column 1 of 3", "Opened link Reopened 1978 column 2 of 3", "Depth Forty metres column 3 of 3" | "Cedar, Reopened 1978, Forty metres table" |
  | Past the last cell | "end of table", "Words between the grids." | the next line of the text ("Words", by word, run 38416874099) |
  | The table whose cells span | "table 3 columns, 5 rows", "Service column 1 of 3", "spans 2 columns Hours column 2 of 3", "row 2 of 5 Service Leaves column 1 of 3", "Hours Arrives column 2 of 3", "row 3 of 5 Service Express column 1 of 3", "Hours Nine column 2 of 3", "Noon column 3 of 3", "row 4 of 5 Service Stopper column 1 of 3", "Hours Ten column 2 of 3", "Three column 3 of 3", "row 5 of 5 Service spans 2 columns Nothing on Sunday column 1 of…", "end of table" | "Service, Hours table", "Leaves, Arrives table", "Express, Nine, Noon table", "Stopper, Ten, Three table", "Nothing on Sunday table" |
  | The table marked as layout | "Left side", "Right side", "Lower left", "Lower right" | "Table row group", recorded once for the two rows |
  | The ruled table of plain cells | "table 2 columns, 2 rows", "North column 1 of 2", "Wet column 2 of 2", "row 2 of 2 South column 1 of 2", "Dry column 2 of 2", "end of table" | "North, Wet table", the page's last line |
  | The long table | "table 3 columns, 41 rows", "Entry column 1 of 3", "Item column 2 of 3", "Sum column 3 of 3", "row 2 of 41 Entry Entry 01 column 1 of 3", "Item Item 01 column 2 of 3" | "Entry, Item, Sum table", "Entry 01, Item 01, Sum 01 table" (the second by word, run 38416874099) |
  | Going into the first table | "In Stations on the branch table No selection. Station row 1 of 4…" | "In Station, Opened, Depth table Station column 1, row 1" |
  | Into the second | "In table No selection. Service row 1 of 5 column 1 of 3" | "In Service, Hours table Service column 1, row 1" |
  | Into the ruled one | "In table No selection. column 1 of 2 North row 1 of 2 column 1 o…" | "In North, Wet table column 1 of 2 North" |
  | Into the long one | "In table No selection. Entry row 1 of 41 column 1 of 3" (at two seconds a key) | "In Entry, Item, Sum table Entry column 1, row 1" |
  | Into a table at a later row | the first cell, whatever was read before | that row: "In Cedar, Reopened 1978, Forty metres table Station Cedar" |
  | Across the header row | "Opened column 2 of 3", "Depth column 3 of 3" | "Opened column 2, row 1", "Depth column 3, row 1" |
  | On into the next row and along it | "row 2 of 4 Station Alder column 1 of 3", "Opened 1901 column 2 of 3", "Depth Twelve metres column 3 of 3" | "Station Alder", "Opened 1901", "Depth Twelve metres" |
  | Down a column to an empty cell, on, and back | "row 3 of 4 Birch blank column 3 of 3", "row 4 of 4 Cedar Forty metres", "row 3 of 4 Birch blank column 3 of 3" | "Birch empty cell", "Cedar Forty metres", "Birch empty cell" |
  | Down the first column, of row header cells | "row 2 of 4 Alder", "row 3 of 4 Birch", "row 4 of 4 Cedar" | "Alder column 1, row 2", "Birch column 1, row 3", "Cedar column 1, row 4" |
  | Down the long table's second column, and up to its header | "row 3 of 41 Item 02", "row 4 of 41 Item 03"; "row 3 of 41 Item 02", "row 2 of 41 Item 01", "row 1 of 41 Item" | "Item 02", "Item 03"; "Item 02", "Item 01", "Item" |
  | Down from a column's last cell | the top of the next column: after "row 5 of 5 spans 2 columns Nothing on Sunday", "row 1 of 5 Service spans 2 columns Hours"; from the last column "end of table" | it stays: "Stopper column 1, row 4", "Wet column 2, row 1" |
  | Control-Option-C on the empty cell | " Depth" | "Depth" |
  | Control-Option-R there | "row 3 of 4" | "Birch" |
  | Control-Option-C twice | " Depth", "Birch blank Cedar Forty metres" | "Depth", "Birch empty cell Cedar Forty metres cell" |
  | Control-Option-R twice | nothing recorded | nothing new recorded; on #476's branch "Depth empty cell", "Birch" |
  | Control-Option-Shift-T, once and twice | nothing recorded | "￼", the row's character in the text, and nothing |
  | Control-Option-C and R on "Item 03" | " Item", "row 4 of 41" | "Item", "row 4 of 41" |
  | The header cell that spans two columns | "spans 2 columns Hours column 2 of 3" | "Hours, Leaves Hours" |
  | The two header cells under it | "row 2 of 5 Service Leaves column 1 of 3", "Hours Arrives column 2 of 3" | "Leaves", "Hours, Arrives Arrives" |
  | The cells under those | "row 3 of 5 Service Express column 1 of 3", "Hours Nine column 2 of 3", "Noon column 3 of 3" | "Service Express", "Hours, Leaves Nine", "Hours, Arrives Noon" |
  | Control-Option-C on Nine and on Noon | " Hours", " Hours" | "Hours, Leaves", "Hours, Arrives" |
  | Control-Option-R on Nine | "row 3 of 5" | "row 3 of 5" |
  | The cell that spans two rows, and down from it | "row 4 of 5 Service Stopper column 1 of 3", "row 5 of 5 spans 2 columns Nothing on Sunday" | "Service Stopper", "Stopper column 1, row 4" |
  | The Actions menu on "1934" | "Actions menu 1 item", "show menu" | "Actions menu 1 item", "Select Cell Text" |
  | Going into that cell, a word, and out | "In text", "1934", "Out of text" | "In text 1934", "1934", "Out of text" |
  | Coming to the cell that is a link | "Opened link Reopened 1978 column 2 of 3" | "Opened Reopened 1978" |
  | Control-Option-F3 there | "Reopened 1978 link is in the VoiceOver cursor" | "Reopened 1978 cell is in the VoiceOver cursor" |
  | Its Actions menu | "Actions menu 2 items", "press", "show menu" | "Actions menu 2 items", "Select Cell Text", "Follow Link: Reopened 1978" |
  | Going into it and out | "In link Reopened 1978 Reopened 1978", "Out of link Reopened 1978" | "In text Reopened 1978", "Out of text" |
  | Following the link | "press" chosen from the menu: "press link Reopened 1978", then "Failed to open page web content", "Safari Can’t Open the Page" | Control-Option-Space on the cell: the page with "Link target reached" was shown, and "word1187 word1188 …", "text word1187 …"; on #476's branch "VoiceOver Verification window Open EPUB… button" |
  | Leaving the table | "Out of table" | "Out of Station, Opened, Depth table" |
  | VoiceOver's hint on a cell | "You are currently on a selectable text, inside of a cell." | "actions available You are currently on a cell, inside of a table…" |

  What the two have in common: a table is "table" to VoiceOver; crossing a row it says the
  column's header and then the cell, and down a column the row's header and then the cell,
  each header once until it changes; Control-Option-C says the column's header; and
  Control-Option-Shift-Down on a cell goes into its words. What Safari adds is VoiceOver's
  speech for a table in a web page: the table's size on arriving and "end of table" after
  it, "row 3 of 4" at each new row and "column 2 of 3" at each cell, "spans 2 columns",
  "blank" for "empty cell", "No selection." on going in, and "link" for a cell that is
  one. What the reader adds: a row's words in one phrase as the text is read, going in at
  the row the listener has reached, both header cells over a column ("Hours, Leaves Nine"),
  and the row's header at Control-Option-R, where Safari gave the row's number. The table
  marked as layout is four items with their words in Safari, and in the reader two lines
  that say "Table row group" and none of the words, as before #476. The next entry has
  what the reader says there since.
  Following the link failed in Safari for what is likely a reason of the session's own:
  the section is a file, and Safari was given that file and not the one beside it. In the
  reader Control-Option-Space on the cell followed the link in both sessions that sent it,
  though the cell has no press. After it VoiceOver read the new page and was on its text
  at `e8032b1`, as it was when Follow Link was chosen from the Actions menu (run
  38391040735); at `f9eb33b` it left the text for the window's first button, which is the
  page turned under a table's element of
  [#485](https://github.com/vocaro/EPUBLib/issues/485). One session each.
  What Safari gives a client of the accessibility API (`ax:tables`): one `AXTable` for a
  table, its title the caption (`AXTitle` "Stations on the branch") and no label, with
  `AXRows` (41 for the long table, 28 or 29 of them `AXVisibleRows`), `AXColumns`,
  `AXVisibleCells`, `AXColumnHeaderUIElements` ("Station", "Opened", "Depth"),
  `AXRowHeaderUIElements` ("Alder", "Birch", "Cedar": three for four rows), `AXHeader`,
  `AXRowCount`, `AXColumnCount` and `AXSelectedCells`, and no `AXSelectedRows`. A cell is
  an `AXCell` with `AXRowIndexRange`, `AXColumnIndexRange` and header cells of its own
  ("Opened" and "Alder" for "1901"); it holds an `AXStaticText` or an `AXLink`, and nothing
  where it is empty, and its actions are `AXShowMenu` and `AXScrollToVisible`. The table
  marked as layout is no table: each of its four cells is a group of the page. The ruled
  table of plain cells is a table with no header.
  Safari has the second table's grid wrong. Its two cells that span rows are one row deep
  (`AXRowIndexRange` 0,1 for "Service" and 3,1 for "Stopper"), so "Leaves" stands in the
  first column, under "Service" and as the header of its row, the column of "Nine" is headed
  by "Hours" alone, and "Nothing on Sunday" covers the first two columns. The reader gives
  "Service" rows 0,2 and "Nothing on Sunday" columns 1,2, as HTML has them. That table's
  rows are children of `table` itself, which XHTML allows and an HTML parser never leaves,
  and WebKit's accessibility code ends a row group after each such row:
  `processTableDescendant` in `AccessibilityNodeObject.cpp` empties its list of
  downward-growing cells before each child of the table and runs the algorithm for ending a
  row group after a row (WebKit at `ef9ea9b`, read on 2026-10-13), where HTML's algorithm
  goes on to the next row. The first table and the long one have `thead` and `tbody`. So how
  Safari reads a header under another, with the grid right, was not heard: the fixture's one
  such table has its rows under `table`.
  VoiceOver quit in Safari at Control-Option-C in three sessions: at the first press, on
  "Item 03" of the long table, at four seconds a key (run 38416874099, session 5), and at
  the eighth press and the ninth in two sessions of the tables of data at two seconds (run
  38419267112, sessions 2 and 4, on the empty cell and on "Three"). It did not in twelve
  presses down the long table's column at two seconds (session 3), nor in the six other
  sessions that pressed the key one to three times. Each time the probe recorded "ERROR 3",
  then "Safari is not responding" or nothing, and VoiceOver's opening phrase. The three
  reports macOS wrote have one backtrace, an exception from `__CFStringCheckAndReplace` in
  `-[SCRWebTableCell columnHeaderDescription]` under
  `-[SCRTable _columnHeaderDescriptionForCellElement:headerIndex:]`: the method for a web
  page's cell beside the one that failed in the reader while a cell named its own header
  cells (the entry above). Safari's cells name theirs. The reader, whose cells name none,
  was pressed Control-Option-C twelve times in its sessions here and did not quit. The
  reports and the three transcripts are for
  [#483](https://github.com/vocaro/EPUBLib/issues/483): the fault shows in Safari with an
  HTML table, without the reader.
  Four reader sessions of run 38416874099 (the first, third, fourth and sixth) sent
  Control-Option-Shift-Down a line early and then read by word; nothing is taken from them
  but the first table and the long one by word. Not heard: anyone listening, or any Mac but
  the runner; Apple Books; the book served over HTTP, or a link followed out of a section in
  Safari; the same tables parsed as HTML; a header under another in a table whose rows stand
  in `tbody`; the reader in continuous scroll or in two columns beside Safari; and VoiceOver
  in another language or with its verbosity changed.
- Later still on 2026-10-13 a table that is not data was heard on a Mac before and after
  its rows were called by their words
  ([Mac VoiceOver reads a group by its name and nothing of what it holds](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#mac-voiceover-reads-a-group-by-its-name-and-nothing-of-what-it-holds)):
  GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), a window 600 points wide at 17
  points, VoiceOver's link setting at Speak, a fixed pause of four seconds, the same steps
  both times. Before at `3f3ae69`, which is `main` but for three commits that change no
  source file built for a Mac: runs 38425341556 (pages), 38425574468 (continuous scroll)
  and 38428695319 (Read All, and by word into the table marked as layout). After at
  `292590e`: runs 38426999381, 38427534348 and 38429468415, the last with a session on
  the section of entries that the run before it did not have. All thirty-five sessions
  completed. Nobody listened. A phrase is cut at 64 characters, shown by "…".
  [#494](https://github.com/vocaro/EPUBLib/pull/494) merged while these were recorded: it
  gives rows in continuous scroll their cells' text areas after every move of the view.
  The seven sessions in continuous scroll were recorded again on the branch with it, at
  `4300466` (run 38431271470), and said at every row and cell what they had said at
  `292590e`, but for the one move marked below.
  The table marked as layout, on the second page of the section of tables of data
  (`"launch=-SampleHref OPS/grids.xhtml" ax:next ax:links "ax:caret=Words before the
  layout" ax:focus in line nextline nextline nextline nextline previousline in right in
  right out left out`). What the text gives a client at the two rows (`ax:links`): before,
  `AXGroup LABEL "Table row"` at each, holding two `AXTextArea`; after, `AXGroup LABEL "Left
  side, Right side"` and `AXGroup LABEL "Lower left, Lower right"`, each holding the same
  two. By line, before: "Words before the layout.", "Table row group", a step with no new
  phrase, "Words after the layout.", and back "Table row group". After: "Words before the
  layout.", "Left side, Right side group", "Lower left, Lower right group", "Words after
  the layout.", and back "Lower left, Lower right group". `in` there, before: "In Table
  row group 2 items text Lower left". After: "In Lower left, Lower right group 2 items
  text Lower left". Then the same both times: `right` "text Lower right", `in` "In text
  Lower right", `right` "Lower", `out` "Out of text", `left` "text Lower left". The last
  `out`, before: "Out of Table row group". After: "Out of Lower left, Lower right group".
  By word from the same line (five `right`, then `in right out right right`), before:
  "Words", "before", "the", "layout.", "Table row group", `in` "In Table row group 2 items
  text Left side", `right` "text Right side", `out` "Out of Table row group", `right`
  "Table row group", `right` "Words". After: the four words, "Left side, Right side
  group", "In Left side, Right side group 2 items text Left side", "text Right side", "Out
  of Left side, Right side group", "Lower left, Lower right group", "Words". The steps
  that followed in that session were sent from a word and are not used.
  Read All from that line (`readall ax:wait=10`), before: "Words before the layout.",
  "Table row group", four seconds with nothing new, "Words after the layout.", "North, Wet
  table". After: "Words before the layout.", "Left side, Right side group", "Lower left,
  Lower right group", "Words after the layout.", "North, Wet table". In continuous scroll
  the same, and on to "South, Dry table".
  The two plain tables of the section with a hidden heading (`OPS/table.xhtml`), pages, by
  line from the top (`in line`, eight `nextline`, `previousline in right in right out
  out`). Before: "Parked table heading", "Table row group", a step with no new phrase,
  "Shown words after the table.", "Line 01 after the table.", "Line 02 after the table.",
  "Table row group", two steps with no new phrase, `in` "In Table row group 2 items text
  Fifth cell", "text Sixth cell", "In text Sixth cell", "Sixth", "Out of text", "Out of
  Table row group". After: "Parked table heading", "First cell, Second cell group", "Third
  cell, Fourth cell group", the three lines, "Fifth cell, Sixth cell group", "Seventh
  cell, Eighth cell link group", back "Fifth cell, Sixth cell group", `in` "In Fifth cell,
  Sixth cell group 2 items text Fifth cell", then the same, and "Out of Fifth cell, Sixth
  cell group". By word back from "Shown" (`left left in right out right right right`),
  before: "Table row group", a step with no new phrase, "In Table row group 2 items text
  First cell", "text Second cell", "Out of Table row group", "Table row group", a step
  with no new phrase, "Shown". After: "Third cell, Fourth cell group", "First cell, Second
  cell group", "In First cell, Second cell group 2 items text First cell", "text Second
  cell", "Out of First cell, Second cell group", "First cell, Second cell group", "Third
  cell, Fourth cell" without "group", "Shown". Read All from the top, after: "Parked table
  heading", "First cell, Second cell group", "Third cell, Fourth cell group", the three
  lines, "Fifth cell, Sixth cell group"; before, "Table row group" in the rows' places.
  The table of links (`OPS/cells.xhtml`), pages, by line. Before: "Shown words before the
  grid.", "Table row group", two steps with no new phrase, "Shown words after the grid.",
  and back the same. After: "Plain first entry., Before the worded jump after it, and
  then en…", "Described: Described entry jump, Bare: group", "Entry jump with decoration,
  Parked entry jump Shown last entry.…", "Shown words after the grid.", and back the same
  three; `ax:links` has the names whole, the first "Plain first entry., Before the worded
  jump after it, and then enough further words to carry this entry on to another line.".
  `in` on the first row, before: "In Table row group 2 items text Plain first entry.".
  After: "In Plain first entry., Before the worded jump after it, and then…", the cell's
  own words past the 64 characters. Then the same: "text Before the worded jump after it,
  and then enough further wo…", "In text Before the worded jump after it, and then",
  "Before", "the", "Out of text". By word, before: "grid.", "Table row group", a step with
  no new phrase, and back two more and "grid.". After: "grid.", the first row, the second,
  and back a step with no new phrase, the first row, "grid.".
  The section of entries, pages, after only (`ax:links ax:focus in line`, five `nextline`,
  three `previousline`, `in right`); what it said before is in the entry on that section
  above, "Table row group" at each row. By line: "Entries follow.", "Upper part closes.
  Lower half opens., Sum x squared stated. grou…", "Drawn Blue entry square shown., Parked
  entry words. Seen entry w…", "Ornament passed., Undescribed stands. group", "Inner one
  Inner two, Beside the inner grid. group". `in` on the first: "In Upper part closes.
  Lower half opens., Sum x squared stated. g…", and `right` "text Sum x squared image
  stated.". The second and third rows' groups offer Inspect Image (`ax:links`).
  Continuous scroll, with the same steps from a line `ax:caret` names. The table marked as
  layout and the table of links said what they said in pages, before and after. The plain tables, back by line from "Shown words after the table."
  and down again, before: "Table row group", a step with no new phrase, "Parked table
  heading", "Table row group", a step with no new phrase, `in` "In Table row group 2 items
  text Third cell". After: "Third cell, Fourth cell group", "First cell, Second cell
  group", "Parked table heading", "First cell, Second cell group", "Third cell, Fourth
  cell group", "In Third cell, Fourth cell group 2 items text Third cell". By word back
  from "Shown", into the first row and out, the next `right` said, before, "First cell
  Second cell image", a tab between the cells, and 55 milliseconds later "Table row
  group", and the one after it "Table row"; after, "First cell, Second cell group", and at
  the one after it "Third cell, Fourth cell group" and 51 milliseconds later "Third cell,
  Fourth cell"; at `4300466`, "Third cell, Fourth cell group" alone. A session that came up through the layout table from the line below it
  and into its first row: "Lower left, Lower right group", "Left side, Right side group",
  "Words before the layout.", "Left side, Right side group", "In Left side, Right side
  group 2 items text Left side", "text Right side", "Out of Left side, Right side group";
  before, "Table row group" in each of those places.
  What was looked for. A row's words are said once as the text is read, by line, by word
  and by Read All, and no cell's words follow them there. On going into a row they are
  said before the first cell's, so that cell's words are heard twice in one phrase, and
  they are said again on leaving. Two rows that follow one another are two lines of a
  transcript now, where "Table row group" twice was one. The one move with two phrases
  for a row, by word after leaving a row in continuous scroll, had two before as well,
  the first of them the row as an image: the second replaces the first within a twentieth
  of a second, so what a listener hears there is the second
  ([harness pitfalls across lanes](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#harness-pitfalls-across-lanes)).
  The second session of each of the first four runs sent `in` on the word before the
  layout table's first row, where it does nothing, and the `out` after it left the text:
  nothing is taken from those four but "Left side, Right side group" for "Table row
  group" by word. The third pair of runs has the steps right.
  Not heard: anyone listening, or any Mac but the runner; a row that shows pictures nobody
  describes and no words, which is still called "Table row"; a row of a table of data that
  shows a picture, which unit tests hold to its table; a row beyond the screen that
  VoiceOver reads to before the view has moved; a spread of two columns; a table in a
  note's popover; the Actions menu on a row's group; Safari on the two plain tables; and
  VoiceOver in another language or with its verbosity changed.
- On 2026-10-13 the two rows that entry left unheard were heard on a Mac, and a row
  without words lost the name the reader had given it: GitHub's hosted `xcode-27` runner
  (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), a window 600 points wide
  at 17 points, VoiceOver's link setting at Speak, a fixed pause of four seconds, on the
  fixture's new last section (`"launch=-SampleHref OPS/squares.xhtml"`). Before at
  `e02ea32`, which is `main` at `6928200` with the section added and nothing of the
  reader changed: run 38436431887. After at `37f2225`: runs 38438620999 and 38440867205.
  [#508](https://github.com/vocaro/EPUBLib/pull/508) and
  [#511](https://github.com/vocaro/EPUBLib/pull/511) merged while these were recorded.
  The first gives a table cell that is one link a press and a link to hold, and the
  second added the section `OPS/parts.xhtml` to the fixture, which this section now
  follows. The six sessions of run 38438620999 were recorded again on the branch merged
  with both, at `eec2108` (run 38443323478): every phrase from the first `in` of each was
  what it had been at `37f2225`, and so was what the text gives at each row. All
  twenty-three sessions completed, and each run reports `"billable": {}`. Nobody
  listened. A phrase is cut at 64 characters, shown by "…".
  The row of two pictures nobody describes, in the table marked as layout, on the
  section's first page (`ax:links "ax:caret=Words before the squares" ax:focus in line`,
  five `nextline`, two `previousline`, `in right in right out out`). What the text gives
  a client at that row (`ax:links`), before: `AXGroup LABEL "Table row" HELP
  "Double-click or choose Inspect Image to enlarge." ACTIONS "Inspect Image","Inspect
  Image" CHILDREN AXTextArea,AXTextArea`. After: the same group with no `LABEL` and no
  `HELP`. Each of its two text areas has U+FFFC for its value, and an `AXImage` with
  Inspect Image at that character. By line, before: "Words before the squares.", a step
  with no new phrase, "Top near, Top far group", "Table row group", "Foot near, Foot far
  group", "Words after the squares.", and back "Foot near, Foot far group", "Table row
  group". After: "text image text image group" in both of that row's places, and the
  rest the same. `in` there, before: "In Table row group 2 items text image". After:
  "In group 2 items text image". Then the same both times: `right` "text image", `in`
  "In text image", `right` "image", `out` "Out of text". The last `out`, before: "Out of
  Table row group". After: "Out of group". By word from the same line, before: "Words",
  "before", "the", "squares.", "Top near, Top far group", "Table row group", "Foot near,
  Foot far group", "Words". After: "text image text image group" at the sixth step, and
  the rest the same. Read All from that line, after only (`readall ax:wait=10`): "Words
  before the squares.", "Top near, Top far group", "text image text image group", "Foot
  near, Foot far group", "Words after the squares.", and in continuous scroll on to
  "Words before the signs.", "Sign, Sense table", "Blue badge, Open table".
  Continuous scroll (`"ax:links=Words before the squares"` for what the text gives, and
  the same steps from the same line) said the same by line, on going in, across and on
  leaving, before and after. One thing differs there, after: with its cursor on the
  group it had just left, VoiceOver said "group" alone as the Actions menu closed, in
  two sessions, and in the second `describe` said "group is in the VoiceOver cursor"
  before the menu and after it. On a page the menu closed on "text image text image
  group". The application posted `AXValueChanged` at that `out` in continuous scroll and
  not on a page, before the change as after it. Moving back by word from the row below
  then said "text image text image group" and 106 milliseconds later "text image text
  image".
  The Actions menu on that row. While VoiceOver read the text, on the row's line by word
  in pages and by line in continuous scroll, after: "Actions menu 3 items", "Previous
  Page", "show menu", "Next Page", or "Scroll Backward", "show menu", "Scroll Forward",
  and on closing "text  word:  text image text image". That is the text area's menu,
  with no picture's action. With its cursor on the group, after `in` and `out`, in
  pages: "Actions menu 6 items", and for seven `listdown` steps "Inspect Image", a step
  with no new phrase, "show menu", "Inspect Image", "show menu", "Inspect Image" and
  nothing: the row's two actions, then two for each cell's text. In continuous scroll:
  "Actions menu 2 items", "Inspect Image" and two steps with no new phrase. Before, in
  pages after `in right in right out out`: "Actions menu 4 items", "Inspect Image", a
  step with no new phrase and "Inspect Image ￼ text"; its fourth item was not stepped
  to, and the menu closed on "Table row group" and the hint "actions available
  Double-click or choose Inspect Image to enlarg…". `"listchoose=Inspect Image"` on the
  menu's first item, after: VoiceOver said "Inspect Image text text", and
  `ax:actions=all` listed Zoom Out, Zoom In, Fit, Close, "Magnification" and an image
  with no name, so the inspector had opened.
  The table of data, at the top of the section's second page (`ax:next ax:lines ax:links
  ax:tables "ax:caret=Words before the signs" ax:focus in line`, five `nextline`, two
  `previousline`, `in right left`), the same before and after. The text gives `AXTable`
  at each of the three rows, called "Sign, Sense", "Blue badge, Open" and "Shut", each
  with its own row selected, three rows and two columns under the headers "Sign" and
  "Sense" (`ax:tables`); the cells that hold the pictures have Inspect Image: Blue badge
  with Select Cell Text, and Inspect Image alone. By line: "Words before the signs.", a
  step with no new phrase, "Sign, Sense table", "Blue badge, Open table", "Shut table",
  "Words after the signs.", and back "Shut table", "Blue badge, Open table". By word the
  same three after "signs.". `in` on the second row: "In Blue badge, Open table Sign ￼",
  `right` "Sense Open", `left` "Sign ￼"; `actions` there "Actions menu 2 items",
  "Inspect Image: Blue badge", "Select Cell Text", and on closing "￼ cell"; `in` on the
  cell "In text Blue badge image", `right` "Blue badge image", and the two `out` "Out of
  text" and "Out of Blue badge, Open table". `in` on the third row: "In Shut table Sign
  ￼"; `in` again "In text image", `right` "image", `out` "Out of text"; `actions` on the
  cell "Actions menu 1 item", "Inspect Image". Continuous scroll said the same
  (`"ax:tables=Words before the signs"`).
  So a row of a table of data that shows a picture is its table, and VoiceOver goes in
  at that row, as the entry above had from a unit test alone. What its cell says was not
  known before: a cell that holds a picture and no words is said by its header and
  U+FFFC, "Sign ￼" in a transcript, for the described picture as for the other. "Blue
  badge" is in the row's name and in the cell's text, and not at the cell. What
  VoiceOver voices for that character nobody heard.
  The steps were not the same in every session of the first two runs. In the first, the
  step meant to open the Actions menu on the row from the text came after a `right` and
  a `left`: `left` straight after `right` says the item again and leaves no line, so the
  menu was opened on the row below, "Foot near, Foot far", in pages and in continuous
  scroll. The second run opened it on the row itself, and went into the described
  picture's cell, which the first had not. The third stepped through the group's menu to
  its end and chose from it. A run started before the first, 38436354231, was given a
  commit that does not exist and was cancelled while it waited for a runner.
  Not heard: anyone listening, or any Mac but the runner; a row of empty cells or of
  decoration alone, which was "Table row group" too and has no name now; a row beyond
  the screen that VoiceOver reads to before the view has moved; the group's Actions menu
  in continuous scroll before the change, and its fourth item in pages; a cell of a
  table of data that holds a picture among words; a spread of two columns; a table in a
  note's popover; Safari on this section; and VoiceOver in another language or with its
  verbosity changed. [#509](https://github.com/vocaro/EPUBLib/issues/509) keeps what is
  left of the rows that entry did not hear.
- On 2026-10-13 the rows of a table that have nothing to say were heard on a Mac, as they
  were and in six other ways, and VoiceOver was then given nothing to stop on at one
  ([a row with nothing to say must fold into the next line](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-row-with-nothing-to-say-must-fold-into-the-next-line)):
  GitHub's hosted `xcode-27` runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`,
  Xcode 27.0), a window 600 points wide at 17 points, VoiceOver's link setting at Speak, a
  fixed pause of four seconds, on the fixture's new last section
  (`"launch=-SampleHref OPS/gaps.xhtml"`). Before at `560fc83`, which is `main` at
  `808ab79` with the section added and nothing of the reader changed: runs 38450767639
  (pages) and 38453220012 (continuous scroll). After at `4dbdc1c`: runs 38459405662
  (pages) and 38459438011 (continuous scroll). Between them, three runs of other ways of
  giving such a row, none of which is the change: 38450810943 at `3971778` and
  38457032228 at `98076a8`, two commits that chose a way at launch and were taken out
  again, and 38454467578 (pages) with 38455014795 (continuous scroll) at `5cd6818`, the
  change as it first stood. Run 38461506908, at `560fc83` again, has one session of each
  flow for a single step of the sessions after.
  [#513](https://github.com/vocaro/EPUBLib/pull/513),
  [#514](https://github.com/vocaro/EPUBLib/pull/514),
  [#519](https://github.com/vocaro/EPUBLib/pull/519) and
  [#520](https://github.com/vocaro/EPUBLib/pull/520) merged while these were recorded.
  The third added a section to the fixture before `OPS/parts.xhtml`, and the fourth a
  table at the end of `OPS/squares.xhtml` and what a cell that shows a picture says; this
  section still follows them, its file what it was. The eleven sessions after were
  recorded again on the branch merged with all four, at `029b901`: runs 38462930391
  (pages) and 38462973976 (continuous scroll). All fifty-four sessions completed, and
  each run reports `"billable": {}`. Nobody listened. A phrase with nothing in it is the probe's record of
  VoiceOver speaking no words. Where VoiceOver left the insertion point after a step (a
  `SELECTION` line of the transcript) tells a step that said nothing from one that did
  nothing.
  The section's first page, before (`ax:lines`): "Words before the gaps." at 0, the table
  marked as layout as seven lines of two characters at 23 to 35, and "Words after the
  gaps." at 37. What the text gave at each row (`ax:links`), in pages: `AXGroup LABEL
  "Upper near, Upper far" … CHILDREN AXTextArea,AXTextArea` at each of the four rows of
  words; at the row of two cells of decoration (29) `AXGroup ACTIONS none CHILDREN
  AXTextArea,AXTextArea` with no label, each text area's value U+FFFC; and nothing at the
  row of two empty cells (25) or at the row of one (33). In continuous scroll
  (`"ax:links=Words before the gaps"`) the same but at the row of two empty cells, which
  had `AXGroup ACTIONS none` with no label and no children.
  By line, before, in pages (`"ax:caret=Words before the gaps" ax:focus in line`, nine
  `nextline`, six `previousline`): "Words before the gaps.", a step with no new phrase,
  "Upper near, Upper far group", a phrase with nothing in it, "Middle near, Middle far
  group", "text text group", "Lower near, Lower far group", a phrase with nothing in it,
  "Last near, Last far group", "Words after the gaps.", and back the same as far as the
  row of two empty cells. The insertion point went to each row in turn, 24, 26, 28 and on
  by twos, the silent ones among them. `in` on that row did nothing, and `describe` said
  "Line 3  word:  is in the VoiceOver cursor Line 3". In continuous scroll (nineteen
  `nextline` through both tables and eighteen `previousline`): "group" at the row of two
  empty cells, and the rest the same.
  By word, before, in pages (`in`, eight `right`): "Words", "before", "the", "gaps.",
  "Upper near, Upper far group", a step with no phrase, "Middle near, Middle far group",
  "text text group". `in` there: "In group 2 items text", `right` "text", `in` "In text",
  `right` nothing, `out` "Out of text", `out` "Out of group". Then "Lower near, Lower far
  group", a step with no phrase, "Last near, Last far group", "Words", "after", and back
  by thirteen `left` the same, a step with no phrase at each of the two rows of empty
  cells. In continuous scroll: "group" at the sixth step, where `in` said "In group
  content is empty" and `describe` "empty group is in the VoiceOver cursor".
  Read All, before (`in readall ax:wait=14`), in pages: the phrases heard by line, in
  order, with a phrase with nothing in it at each of the two rows of empty cells; in
  continuous scroll "group" at the first of those.
  The table of data, at the top of the second page (`ax:next`), before. The text gave
  `AXTable` at each of its eight rows, with that row selected, eight rows and two columns
  under "Tree" and "Tally", and those at the three rows with nothing to say have no label
  (`ax:links`, `ax:tables`). By line, by word and with Read All, in pages and in
  continuous scroll: "Tree, Tally table", "Oak, Nine table", "table", "Elm, Four table",
  "table", "Ash, Six table", "table", "Yew, Two table", forward and back. `in` on the row
  of two empty cells: "In table Tree empty cell", `right` "Tally empty cell", `nextline`
  "Four", `out` "Out of table", and `describe` "table 2 columns, 8 rows is in the
  VoiceOver cursor". On the row of decoration: "In table Tree ￼", `right` "Tally ￼". On
  the row of one empty cell: "In table Tree empty cell", and `right` went on to "Yew".
  Four other ways, run 38450810943, in pages on the table marked as layout, each for all
  three rows (`in line`, `nextline` to the page's last line, `previousline` back to its
  first, fourteen `right`). Static text without words as the element at the row's
  character: a phrase with nothing in it by line and a step with no phrase by word at
  each of the three rows, as with no element. No element and the character given as a
  space, in the text's value, its string and its attributed string: by line still a
  phrase with nothing in it at each row, in both directions; by word "Upper near, Upper
  far group", "Middle near, Middle far group", "Lower near, Lower far group", "Last near,
  Last far group", "Words", with no step between them, the insertion point going from 24
  to 28, 32 and 36. No element, the attachment's character left, and the row's line given
  as part of the line before (`ax:lines` prints six lines, the first three rows of words
  four characters long): by line the four rows of words and no phrase between them,
  forward and back, the insertion point at 26, 30, 34 and 36; by word a step with no
  phrase after each of the first three. Both, a space and the line before: no stop by
  line, forward or back, and none by word.
  That last way as the change first stood, at `5cd6818`, runs 38454467578 and 38455014795,
  in pages and in continuous scroll and on both tables: by line and by word, forward and
  back, the rows of words and nothing between them, "Tree, Tally table", "Oak, Nine
  table", "Elm, Four table", "Ash, Six table", "Yew, Two table" in the table of data. Two
  things were wrong with it. Read All still had a phrase with nothing in it after each
  row of words that a row with nothing to say follows. And `in` on such a row of words
  reached by line did nothing, in pages and in continuous scroll: after two `nextline` to
  "Middle near, Middle far group", with the insertion point at 30, after the space, `in`
  left no phrase, `right` said "Lower near, Lower far group", and `out` said "Out of
  text" and left the text area, "text is in the VoiceOver cursor"; the same on "Elm, Four
  table". Reached by word, with the insertion point straight after the row's own
  character, `in` went in: "In Middle near, Middle far group 2 items text Middle near",
  "In Elm, Four table Tree Elm". Before the change `in` on a row reached by line went in,
  as on the row of two empty cells of the table of data above.
  Two more ways, run 38457032228, in pages, with the row's line part of the line after it
  (`ax:lines`: "Upper near, Upper far" alone at 23, and three lines of four characters at
  25, 29 and 33). With the break after the row left as it is: by line "Upper near, Upper
  far group" and then a phrase with nothing in it for each of the three lines that begin
  with such a row, forward and back, the insertion point at 28, 32 and 36, which is after
  each row of words; `in` on the first of them went in, "In Middle near, Middle far group
  2 items text Middle near", `right` "text Middle far", `out` "Out of Middle near, Middle
  far group". Read All had the phrases with nothing in them still. In the table of data
  the same: nothing said for "Elm, Four", and `in` there "In Elm, Four table Tree Elm",
  `right` "Tally Four", `nextline` "￼", the cell of decoration below, `nextline` "Six".
  With the break given as a space too: by line "Upper near, Upper far group", "Middle
  near, Middle far group", "Lower near, Lower far group", "Last near, Last far group",
  forward and back; `in` after two `nextline` "In Middle near, Middle far group 2 items
  text Middle near", and `describe` after `out` "Middle near, Middle far group is in the
  VoiceOver cursor"; by word the same four rows, forward and back, and `in` on the
  second; Read All "Words before the gaps.", the four rows and "Words after the gaps.",
  with no phrase between them.
  After, at `4dbdc1c`, in pages. The first page's lines (`ax:lines`): "Words before the
  gaps." at 0, "Upper near, Upper far" alone at 23, three lines of four characters at 25,
  29 and 33, each two spaces and a row of words, and "Words after the gaps." at 37. The
  text gives the four groups, at 23, 27, 31 and 35, and nothing at the three rows between
  them (`ax:links`, four runs). By line (`in line`, six `nextline`, five `previousline`):
  "Words before the gaps.", a step with no new phrase, "Upper near, Upper far group",
  "Middle near, Middle far group", "Lower near, Lower far group", "Last near, Last far
  group", "Words after the gaps.", and back the four rows and "Words before the gaps.",
  the insertion point at 24, 28, 32 and 36, straight after each row of words. `in` after
  two `nextline` from there: "In Middle near, Middle far group 2 items text Middle near",
  `right` "text Middle far", `out` "Out of Middle near, Middle far group", `describe`
  "Middle near, Middle far group is in the VoiceOver cursor". By word (`in`, six `right`):
  "Words", "before", "the", "gaps.", "Upper near, Upper far group", "Middle near, Middle
  far group"; `in` there the same, `right` "text Middle far", `in` "In text Middle far",
  `right` "Middle", `out` "Out of text", `out` "Out of Middle near, Middle far group";
  then "Last near, Last far group", "Words", "after" at the second, third and fourth
  `right`, and back by ten `left` a step with no new phrase, "Words", "Last near, Last
  far group", "Lower near, Lower far group", "Middle near, Middle far group", "Upper near,
  Upper far group", "gaps.", "the", "before", "Words". The first `right` after that last
  `out` took the insertion point to 32, the row "Lower near, Lower far", and the phrase
  recorded for it is "Middle", the word last read inside the cell, 35 milliseconds
  after the move. That is not the change's doing: on the reader as it was
  (run 38461506908, the same steps on the same row, in pages) the step went to the row of
  decoration, and the transcript has "text text group" and 52 milliseconds later
  "Middle"; in continuous scroll there, "group" and then "text text". So in pages, with
  either reader, a listener who has read a word of a cell hears that word again at the
  first move by word after leaving the row, where the next row is due, and the `right`
  after that says the row after it. A move by line after
  moves by word (five `right` to "Upper near, Upper far group", two `nextline`): "Middle
  near, Middle far group", "Lower near, Lower far group". Read All (`readall
  ax:wait=12`): "Words before the gaps.", the four rows and "Words after the gaps.", and no
  phrase between them.
  The table of data, after, on the second page: "Tree, Tally" at 24 and "Oak, Nine" at 26
  as lines of two characters, three lines of four at 28, 32 and 36, and "Words after the
  tally." at 40. The text gives five tables, at 24, 26, 30, 34 and 38, each with all
  eight rows and its own row selected, the first, second, fourth, sixth and eighth
  (`ax:links`, `ax:tables`). By line (seven `nextline`, six `previousline`) and by word
  (seven `right` and four more, eleven `left`): "Tree, Tally table", "Oak, Nine table",
  "Elm, Four table", "Ash, Six table", "Yew, Two table", forward and back. `in` on the
  third, reached by line: "In Elm, Four table Tree Elm", `right` "Tally Four", `nextline`
  "￼", which is the cell of decoration in the row below, `nextline` "Six", `out` "Out of
  Elm, Four table", and `describe` "Elm, Four table 2 columns, 8 rows is in the VoiceOver
  cursor". Reached by word: "In Elm, Four table Tree Elm", "Tally Four", "Out of Elm,
  Four table". Read All: "Words before the tally.", the five rows, "Words after the
  tally." and "Line 01 after the tally.".
  After, in continuous scroll (`"ax:links=Words before the gaps"`, `"ax:tables=Words
  before the tally"`): the four groups are four characters apart, at 23053 to 23065, and
  the text gives five tables. By line through both tables (thirteen `nextline`, twelve
  `previousline`): "Words before the gaps.", the four rows, "Words after the gaps.",
  "Words before the tally.", the five rows, "Words after the tally.", and back the same.
  `in` on "Middle near, Middle far group" and on "Elm, Four table", each reached by line
  and by word, said what it says in pages, and inside the table `nextline` said "￼" and
  "Six". By word forward, and back from "Words after the tally." by nineteen `left`: the
  same rows and words, none between them. Read All from "Words before the gaps." read on
  through both tables to "Line 02 after the tally." with no phrase between two rows. As
  before the change, each row said by `right` after an `out` there left its phrase and
  then its words again without "group" or "table".
  On the branch merged with `main` at `d5ad34a`, at `029b901`, the same eleven sessions,
  step for step: every phrase the same but two things, which are `main`'s. Inside the
  table of data `nextline` from "Tally Four" said "empty cell" where it had said "￼", the
  cell of decoration, which #520 made an empty cell; and in continuous scroll each row
  said by `right` after an `out` left one phrase, where it had left its phrase and then
  its words again. The lines, what the text gives at each row, by line and by word
  forward and back, both `in` after a move by line, both after a move by word, and Read
  All in both flows were what they were at `4dbdc1c`.
  [#518](https://github.com/vocaro/EPUBLib/pull/518) merged after that and changes two
  files of the iPhone and iPad reader; nothing was recorded again for it.
  So a row with nothing to say is passed over when the text gives no element at its
  character, gives the character and its break as spaces, and has the row's line begin
  the line of what follows. Each of the other six ways left VoiceOver something: a stop
  in silence, a line it said nothing of, or a row of words it would not go into.
  Not heard: anyone listening, or any Mac but the runner; rows with nothing to say that
  end a page or the book, which are one line together, and a page of nothing else; a row
  that opens a section; two such rows together; a row of spaces; a row without words that
  holds a link or a rule, which is not passed over; a table inside a table cell; a spread
  of two columns; a note's popover; Safari on this section; and VoiceOver in another
  language or with its verbosity changed.
  [#529](https://github.com/vocaro/EPUBLib/issues/529) keeps these,
  [#527](https://github.com/vocaro/EPUBLib/issues/527) the row that holds a link or a
  rule, [#458](https://github.com/vocaro/EPUBLib/issues/458) the table inside a cell, and
  [#528](https://github.com/vocaro/EPUBLib/issues/528) the word said again after a cell
  is left.
- Later again on 2026-10-13 a table cell that is a link was heard on a Mac before and
  after it was given a press and a link to hold
  ([a Mac cell is read by what it holds, not by what it says it is](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-tables.md#a-mac-cell-is-read-by-what-it-holds-not-by-what-it-says-it-is)):
  "Reopened 1978" in the first table of the
  section of tables of data (`-SampleHref OPS/grids.xhtml`), on GitHub's hosted `xcode-27`
  runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points
  wide at 17 points, with VoiceOver's link setting at Speak, at a fixed pause of four
  seconds, the same steps both times. Before at `3f3ae69`, which was `main`: run
  38426000629. After at `0474384`: runs 38428891242 and 38430983860; the commits after it
  change comments and documents. With `main` at `b515264` merged in (`9bd3d3f`), the first
  session and the fourth were recorded once more and said the same (run 38433434953).
  Nobody listened. The harness was the branch's own, before and after `main` with the
  sessions of Safari was merged into it.
  Four sessions each time: along the row to the cell with its Actions menu, and down the
  column to it, in pages and then in continuous scroll. The way in was `ax:caret=Stations
  on`, a focus change to the text, `in`, `line` and five `nextline` to "Cedar, Reopened 1978,
  Forty metres table", `in` and `right`; or four `nextline` to "Birch, 1934 table", `in`,
  `right` and `nextline`. A phrase is cut at 64 characters, shown by "…".

  | Move | Before | After |
  | --- | --- | --- |
  | Along the row to the cell | "Opened Reopened 1978" | "Opened Reopened 1978 hyperlink" |
  | Down the column to it | "Cedar Reopened 1978" | "Cedar Reopened 1978 hyperlink" |
  | The hint that follows | "actions available You are currently on a cell, inside of a table…" | "actions available You are currently on a hyperlink cell, inside…" |
  | Control-Option-F3 | "Reopened 1978 cell is in the VoiceOver cursor" | "Reopened 1978 hyperlink hyperlink cell is in the VoiceOver curso…" |
  | The Actions menu | "Actions menu 2 items", "Select Cell Text", "Follow Link: Reopened 1978" | "Actions menu 3 items", "Select Cell Text", "Follow Link: Reopened 1978", "press" |
  | Closing the menu | "Closing Actions menu", "Reopened 1978 cell" | "Closing Actions menu", "Reopened 1978 hyperlink hyperlink cell" |
  | Control-Option-Space in pages | the page with "Link target reached" was shown; "VoiceOver Verification window Open EPUB… button" | the same page; "word1187 word1188 …", "text word1187 …" |
  | Control-Option-F3 after it | "Open EPUB… button is in the VoiceOver cursor" | "text is in the VoiceOver cursor Line 1" |
  | Control-Option-Down, Control-Option-Shift-Down and Control-Option-L after that | "Previous Page button", "Interact with the title of button", nothing | nothing new, "In text word1187 …", "word1187 … word1193" |
  | Control-Option-Space in continuous scroll | the view at "Link target reached"; "Link", "text Page boundary verification" | the same, phrase for phrase |
  | Control-Option-F3 after it | "text is in the VoiceOver cursor Line 202" | the same |
  | Control-Option-Shift-Down and Control-Option-L after that | "In text Link target reached", "Link target reached" | the same |
  | The cell in `ax:tables` | `AXCell` that holds `AXTextArea`, with the actions "Select Cell Text" and "Follow Link: Reopened 1978" | `AXCell` that holds `AXLink`, with `AXPress` and the same two |

  Every row but the two for a flow was the same in pages and in continuous scroll, and
  along the row as down the column. By line the row was "Cedar, Reopened 1978, Forty metres
  table" before and after.
  Into the cell's words, after (run 38430983860, session 1, in pages): `in` "In hyperlink
  Reopened 1978 text Reopened 1978", `in` "In text Reopened 1978", `right` "Reopened", `out`
  "Out of text" and the hint "You are currently on a text area, inside of a hyperlink.",
  `out` "Out of hyperlink Reopened 1978", and Control-Option-F3 the cell again. Before, one
  `in` went into the text, "In text Reopened 1978" (run 38422077936). Find Next Link from
  the page's first lines, after (session 2): "Reopened 1978 hyperlink", "You are currently
  on a hyperlink, inside of a text area…", and Control-Option-Space followed it. It was not
  sent before.
  Where VoiceOver was after the link was followed, for
  [#485](https://github.com/vocaro/EPUBLib/issues/485). In pages, pressed from the cell
  with VoiceOver not having been in its words, it was on the new page's text area and not
  in it, a Control-Option-Shift-Down from the page's first line: both sessions after, and
  the two of the trial below that had a press and a cell holding its text area. Before,
  with no press, it was on the window's first button, "Open EPUB…", out of the text, in
  both sessions; the one session of run 38422077936 on the same reader, which had been
  into the cell's words and along the row first, ended on the new page's text. After,
  pressed once VoiceOver had been into the cell's words and back out (run 38430983860,
  session 1), it was on "Open EPUB…" again, as in the three sessions of the trial that
  went into the cell first. Find Next Link from the page and Control-Option-Space left it
  on the new page's text area. In continuous scroll it was on the text area each time,
  entering at the target's line.
  What makes VoiceOver say that the cell is a link was found by trial, at `a9a2d30` (run
  38425952070, seven sessions) and `dbca416` (run 38428938679, two), each a way of giving
  the cell chosen at launch, all with the press, in pages, along the row:

  | The cell | Coming to it | Control-Option-F3 | Going in | Control-Option-Space |
  | --- | --- | --- | --- | --- |
  | Holds its text area, with a press and no more | "Opened Reopened 1978", "…on a cell, inside of a table…" | "Reopened 1978 cell is in the VoiceOver cursor"; the Actions menu has 3 items | not sent | followed; "text is in the VoiceOver cursor Line 1" |
  | The same with the subrole of a link in text | the same | the same | not sent | not sent |
  | The same with a link's role description | "Opened Reopened 1978", "…on a hyperlink, inside of a…" | "Reopened 1978 hyperlink is in the VoiceOver cursor" | not sent | not sent |
  | The same with both | as with the role description | the same | not sent | followed; "text is in the VoiceOver cursor Line 1" |
  | Has a link's role itself | passed over: from "Station Cedar", "Depth Forty metres" | "Forty metres cell is in the VoiceOver cursor" | not sent | on "Forty metres", nothing |
  | Holds a link called by its words, and no text area | "Opened Reopened 1978 hyperlink", "…on a hyperlink cell, inside…" | "Reopened 1978 hyperlink hyperlink cell is in the VoiceOver curso…" | "In hyperlink Reopened 1978 content is empty", and the next move left the cell | not sent on the cell |
  | Holds a link that holds its text area | the same | the same | "In hyperlink Reopened 1978 text Reopened 1978", "Out of hyperlink Reopened 1978" | followed; "Open EPUB… button is in the VoiceOver cursor" |
  | Holds a link and then its text area | "Opened hyperlink, Reopened 1978 hyperlink" | "hyperlink, Reopened 1978 hyperlink cell 2 items is in the VoiceO…" | "In hyperlink, Reopened 1978 hyperlink cell 2 items text Reopened…", then "hyperlink" | followed; "Open EPUB… button is in the VoiceOver cursor" |
  | Holds its text area and then a link | "Opened Reopened 1978 hyperlink, hyperlink" | "Reopened 1978 hyperlink, hyperlink cell 2 items is in the VoiceO…" | "In Reopened 1978 hyperlink, hyperlink cell 2 items text Reopened…", then "hyperlink" | followed; "Open EPUB… button is in the VoiceOver cursor" |

  The reader keeps the link that holds the text area: the one way that said "hyperlink"
  once on coming to the cell and left its words to be read by word. The three sessions
  that ended on "Open EPUB…" had gone into the cell before the press.
  VoiceOver did not quit. Three sessions at two seconds a key on the code as it is, two in
  pages and one in continuous scroll (run 38428891242, session 5, and run 38430983860,
  sessions 3 and 4), each went through the first table's cells with Control-Option-C after
  each of eleven moves and Control-Option-R after each of eleven back, the link cell twice
  among them: "Opened Reopened 1978 hyperlink", "Opened", and on the way back "Cedar".
  None has "ERROR" in it or VoiceOver's opening phrase a second time, and no run has a
  crash report; the same is so of the other twenty-one sessions here.
  Not heard: anyone listening, or any Mac but the runner; "press" chosen from the Actions
  menu; a link cell far off the screen in continuous scroll, whose link is called by the
  cell's words and holds nothing; a cell whose link is a picture; a link cell continued on
  the next page; a header cell that is a link, which has the press and holds its own text
  area (heard since: the next entry); a cell with words beside its link or with two links,
  which unit tests hold to no press; a link whose target is already on the page; a spread
  of two columns; and Safari beside it again.
- Last on 2026-10-13 a header cell that is a link was heard on a Mac, before and after it
  was given a link to hold: the table of the section of header cells that are links
  (`-SampleHref OPS/edges.xhtml`), which was added for it, on GitHub's hosted `xcode-27`
  runner (image `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600
  points wide at 17 points, with VoiceOver's link setting at Speak, at a fixed pause of
  four seconds. Nobody listened. Before is the reader of
  [#508](https://github.com/vocaro/EPUBLib/pull/508) with the section added (`8e99caf`
  with no launch argument, run 38438639310, sessions 1 and 4). After is `0399bce` (run
  38443342254), and with `main` at `9a8e66b` merged in, `9537d19` (run 38446095467), where
  the two sessions were recorded once more and said the same: phrase for phrase in pages,
  and in continuous scroll but for a line of the page that VoiceOver read on to, or not,
  after the link was followed.
  The same steps each time. In pages: `ax:caret=Words before the routes`, a focus change
  to the text, `in`, `line` and two `nextline` to "Route, Built, Length table", then `in
  right nextline columnheader rowheader left describe actions listdown listdown listdown
  listclose nextline nextline right previousline left activate`. In continuous scroll the
  same way in, then `in right nextline columnheader rowheader left nextline right
  previousline previousline describe activate`. A phrase is cut at 64 characters, shown
  by "…".

  | Move | Before | After |
  | --- | --- | --- |
  | Into the table at its header row | "In Route, Built, Length table Route column 1, row 1" | the same |
  | Along the header row to the column's header cell, a link | "Built column 2, row 1" | "Built hyperlink column 2, row 1" |
  | The hint that follows | "actions available You are currently on a cell, inside of a table…" | "actions available You are currently on a hyperlink cell, inside…" |
  | Down its column to the cell under it | "Dogwood 1912" | the same |
  | Control-Option-C and Control-Option-R there | "Built", "Dogwood" | the same |
  | Along the row to the row's header cell, a link | "Route Dogwood" | "Route Dogwood hyperlink" |
  | Control-Option-F3 | "Dogwood cell is in the VoiceOver cursor" | "Dogwood hyperlink hyperlink cell is in the VoiceOver cursor" |
  | The Actions menu | "Actions menu 3 items", "Select Cell Text", "Follow Link: Dogwood", "press" | the same |
  | Closing the menu | "Closing Actions menu", "Dogwood cell" | "Closing Actions menu", "Dogwood hyperlink hyperlink cell" |
  | Down the column of row headers to the next, a link | "Elm column 1, row 3" | "Elm hyperlink column 1, row 3" |
  | And to the next, of plain words | "Fir column 1, row 4" | the same |
  | Along that row to a link cell under the link that heads its column | "Built Relaid 1960 hyperlink" | the same |
  | Up the column, and along the row to its header | "Elm 1947", "Route Elm" | "Elm 1947", "Route Elm hyperlink" |
  | Control-Option-Space there, in pages | the page with "Link target reached" was shown; "word1187 …", "text word1187 …" | the same |
  | Control-Option-F3 after it | "text is in the VoiceOver cursor Line 1" | the same |
  | Up the column to the column's header cell, in continuous scroll | "Built" | "Built hyperlink" |
  | Control-Option-F3 there | "Built cell is in the VoiceOver cursor" | "Built hyperlink hyperlink cell is in the VoiceOver cursor" |
  | Control-Option-Space there | the view at "Link target reached"; "Link", "text Page boundary verification" | the same |
  | Control-Option-F3 after it | "text is in the VoiceOver cursor Line 202" | the same |
  | A header cell that is a link in `ax:tables` | `AXCell` that holds `AXTextArea`, with `AXPress`, "Select Cell Text" and "Follow Link: Built" | `AXCell` that holds `AXLink`, with the same three |

  Every row but those for a flow was the same in pages and in continuous scroll. By line
  the header row was "Route, Built, Length table" before and after. The other rows were
  heard after, "Dogwood, 1912, Nine miles table", "Elm, 1947, Four miles table" and "Fir,
  Relaid 1960, Six miles table" (run 38443342254, session 5), and `ax:tables` gave each
  row's table those words for its label before.
  How the header cell is to hold its link was found by trial, each way chosen at launch in
  one build: `8e99caf` (run 38438639310, three ways in pages and in continuous scroll,
  which agreed) and `91e8297` (run 38441259597, five in pages). In every one the cell has
  the press and holds a link with its text area inside; they differ in what the link or
  the cell is called and in what the table gives as the header of the row or column:

  | The header cell | Coming to it | Coming to a cell it heads | Control-Option-C and -R there |
  | --- | --- | --- | --- |
  | Holds its text area, as before | "Built column 2, row 1", "Elm column 1, row 3" | "Dogwood 1912" | "Built", "Dogwood" |
  | Holds a link without a title, as other cells then did | "Built hyperlink column 2, row 1", "Elm hyperlink column 1, row 3" | "1912", and "column 2 of 3 Relaid 1960 hyperlink" along the row | "column 2 of 3", "row 2 of 4" |
  | The same, and the table gives the header by its words, as static text | "Built Built hyperlink", "Elm Elm hyperlink" | "Dogwood 1912" | "Built", "Dogwood" |
  | The same, and the table gives the cell's text area as the header | "Built Built hyperlink", "Elm Elm hyperlink" | "Dogwood 1912" | "Built", "Dogwood" |
  | The same, and the table gives the cell's link as the header | "column 2 of 3 Built hyperlink", "Elm hyperlink" | "1912" | "column 2 of 3", "row 2 of 4" |
  | Holds a link without a title, and has its words for its own value | "Built hyperlink column 2, row 1", "Elm hyperlink column 1, row 3" | "1912" | "column 2 of 3", "Dogwood" |
  | Holds a link with the cell's words for its label | as with the title | "Dogwood 1912" | "Built", "Dogwood" |
  | Holds a link with the cell's words for its title | "Built hyperlink column 2, row 1", "Elm hyperlink column 1, row 3" | "Dogwood 1912" | "Built", "Dogwood" |

  Along its own row every way but the first said "Route Dogwood hyperlink". The reader
  keeps the title: VoiceOver reads a header cell before the cells it heads by what each
  thing the cell holds is called, a text area's value or a link's title or label, and no
  further in. A header that is not the cell itself is said before the cell too. The title
  is on the link of every cell that is one link, on screen as off it. The words are said
  once on coming to such a cell, and the way in is as it was before the title (run
  38443342254, session 5, in pages): on "Relaid 1960", which is no header, `describe`
  "Relaid 1960 hyperlink hyperlink cell is in the VoiceOver cursor", `in` "In hyperlink
  Relaid 1960 text Relaid 1960", `in` "In text Relaid 1960", `right` "Relaid", `out` "Out
  of text" and `out` "Out of hyperlink Relaid 1960"; on the header cell "Elm", `in` "In
  hyperlink Elm text Elm" and `out` "Out of hyperlink Elm".
  VoiceOver did not quit. Two sessions at two seconds a key on `0399bce`, in pages and in
  continuous scroll (run 38443342254, sessions 3 and 4), went through the table's twelve
  cells with Control-Option-C after each of eleven moves on and Control-Option-R after
  each of eleven back, the three header cells that are links twice each, and said the
  same as each other at every step: "Route Dogwood hyperlink" and "Route", "Built 1912"
  and "Built", and on the way back "Built 1947" and "Elm", "Route Elm hyperlink" and "row
  3 of 4". On a cell of the header row Control-Option-C said the row's words, "Route,
  Built, Length", on "Built" and on "Length" alike, which was not on record, and
  Control-Option-R "row 1 of 4", as it had. None of the twenty-two sessions of the five
  runs has "ERROR" in it or VoiceOver's opening phrase a second time, and no run has a
  crash report.
  The book's links, with the section's four among them, at `9537d19` (run 38446095467,
  session 3): in continuous scroll from the top of the book twenty-four `nextlink` steps
  named twenty-one links in order. After "Reopened 1978" came "routes." and "hyperlink
  Built", the header row being below the screen, then "Dogwood hyperlink", "Elm
  hyperlink" and "Relaid 1960 hyperlink", then "an" and "hyperlink upper jump", "lower
  jump hyperlink" and "last jump hyperlink", and the last three again.
  One fault was found on the way, and it is not the header cell's: it was there with the
  header cell as it was. With the reader opened in continuous scroll at the section of
  tables of data (`-SampleHref OPS/grids.xhtml`, `ax:caret=Stations on`), `nextlink` said
  "Reopened 1978 hyperlink", and the next one, to "Built" some screens below, said
  "routes." and then "text Page boundary verification": `describe` gave "text is in the
  VoiceOver cursor Line 640", and `ax:links` listed "Dogwood", "Elm" and "Relaid 1960" as
  the text's links and no "Built", though its row was on screen (`VISIBLE 19659,268`, the
  row at 19713). Further `nextlink` steps said the three and began again with "Dogwood".
  That is the header cell as it was, at `8e99caf` (run 38446046206). After, at `0399bce`,
  the steps said the same (run 38443342254, session 6). At `9537d19`, whose book has the
  links of the section of parts below a jump after these, "Built hyperlink" was begun
  before "routes.", the text's links were the three and "upper jump", and the steps went
  on through that section's (run 38446095467, session 4). Walked to from the top of the
  book the same link was said, as above. The fault is the reader's
  ([#517](https://github.com/vocaro/EPUBLib/issues/517)), and the entry after this one
  has its cause and the change made for it.
  Not heard: anyone listening, or any Mac but the runner; a header cell that is a link
  while it is off screen in continuous scroll or on another page than the cells it heads,
  where the table gives the header by its words as for any header cell, which unit tests
  hold; a column under two header cells one of which is a link; a header cell with words
  beside its link, which has no press; "press" chosen from the Actions menu; a larger text
  size; a spread of two columns; and Safari beside it.
- After that on 2026-10-13 the fault the entry above found on the way was traced to the
  reader and put right
  ([accessibility observation can change layout](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/textkit-layout.md#accessibility-observation-can-change-layout)):
  in continuous scroll, in a reader opened at a section, Find Next
  Link to a link in a table row some screens below left VoiceOver on the text area, with
  the row on screen and its link out of the text's links
  ([#517](https://github.com/vocaro/EPUBLib/issues/517)). Hosted `xcode-27` runner, macOS
  27.0.1, 600 wide at 17 points, a fixed pause of four seconds, link setting Speak, nobody
  listening. The steps, in a reader launched with `-SampleHref OPS/grids.xhtml`:
  `ax:caret=Stations on ax:focus in nextlink nextlink ax:links describe` and four more
  `nextlink`.
  Before, in a build with the change switched off at launch (`8327e2a`, run 38453482423,
  session 1), as in the three runs of the entry above: "Reopened 1978 hyperlink", then
  "Built hyperlink", "routes." and "text Page boundary verification"; `ax:links` listed
  "Dogwood", "Elm", "Relaid 1960" and "upper jump"; `describe` said "text is in the
  VoiceOver cursor Line 640"; and the next step said "Dogwood hyperlink". After, at
  `5f2faf5` (run 38455085918, session 1): "Reopened 1978 hyperlink", then "Built
  hyperlink", "hyperlink Built" and the hint, "You are currently on a hyperlink, inside of
  a text area…"; `ax:links` listed "Built" first, then the four; `describe` said
  "hyperlink is in the VoiceOver cursor"; and the next steps said "Dogwood hyperlink",
  "Elm hyperlink", "Relaid 1960 hyperlink", and "an" and "hyperlink upper jump". `STATE`
  was the same before and after, `SELECTION 19713,0 VISIBLE 19659,268`.
  The cause was read from a reader that logs what VoiceOver asks of the scroll view's
  text, its links and its table cells, and what the reader does about it (`b89cdfd`, run
  38451213622, session 1, which said the fault). VoiceOver focused the link's element and
  the reader showed the row where TextKit 2 estimated it stood, 23,852 points down, at the
  top of a visible area 519 points high. The text between had not been laid out: eighty
  lines, the table of forty rows and the row of 2,600 words, whose height was a guess.
  Within a tenth of a second VoiceOver asked the element whether it had the focus, which
  it had, then the text for its selected range, for the line its insertion point was on
  (`AXInsertionPointLineNumber`, 639, in 8 ms where the same question then took under
  one), for that line's range and for its bounds: `AXBoundsForRange 19713,2` came back 829
  points below the bottom of the screen. AppKit counts lines from the text's first, so the
  question had laid out all the text above the row. The row of 2,600 words took its
  height, 2,145 points, and the header row's own paragraph stood at 25,282, 1,430 points
  below where the view drew it, while the three rows after it stood where they were drawn,
  at 23,886, 23,919 and 23,953. Then VoiceOver asked the text for its children. The header
  row was no longer the row kept for the next link, so the reader looked for the rows on
  screen, in that layout: the header row was not among them and the row of 2,600 words
  was, and the header row's cells were taken away. The children were "Dogwood", "Elm",
  "Relaid 1960", "upper jump" and the next heading, and VoiceOver, whose link was not
  among them, was on the text area. Nothing moved the view afterwards, so it stayed so.
  It is not the row being its table's first, and not the distance by itself: it is a row
  shown where it is estimated to stand, with text between that is far from its estimate,
  and the text above then laid out behind the view. A unit test with the link in a table's
  second row fails the same way without the change. Why the walk from the top of the book
  said the link all along was not read from a log: no walk was logged. In the reader's
  code the difference would be in how it reaches the row: where its first scroll to the
  estimated place does not bring the row to the top it lays out the text from the screen
  to the row in one run, and nothing is left to move (`scrollLineToTop`); where the
  estimate lands, as in the logged session, the text between stays estimated.
  The change: the scroll view is held to its text, as it is before the reader's own read
  of the screen, before the rows on screen are looked for and before an assistive client
  is told what is on screen and where: the text's children, the bounds of a range, a
  link's or a heading's place and a table row's. The bounds of a range are given a second
  time when answering is what moved the text. In the logged session with the change
  (`8327e2a`, run 38453482423, session 2) the first answer was the same 829 points below
  the screen, the reader scrolled 1,430 points to where the row stood, the rows kept their
  cells, and the answer given was on screen.
  That build held the view in one scroll, and the same run showed that it is not always
  enough. With no `ax:caret` step (`ax:focus in nextlink nextlink describe line nextline`,
  session 3) VoiceOver asked for the bounds of its line as it went into the text, the
  layout above took 10,866 points, and the scroll stopped 5,365 points short at the end of
  a document that was still 12,312 points high and became 23,176 in that same scroll. The
  view showed text of another section, VoiceOver scrolled it on by the scroll bar's value,
  and the reader, taking that for a person's scroll, put the insertion point on the first
  line then on screen, in the book's last section: "In text Tables of data" was followed
  by "parts.", and the next `nextlink` went to "Built" and passed "Reopened 1978" by. So
  the reader scrolls again until the line stands as far below the top as it stood, and the
  rows on screen keep their cells while it does. At `5f2faf5` the same steps said "In text
  Tables of data", "Reopened 1978 hyperlink", "Built hyperlink", "routes." and "hyperlink
  Built", `describe` "hyperlink is in the VoiceOver cursor", and `line` "Route, Built,
  Length table" (run 38455085918, session 2).
  What else was heard at `5f2faf5` in that run, each as before the change. A row that is
  not its table's first, from the section before it (`-SampleHref OPS/cells.xhtml`,
  `ax:focus in` and six `nextlink`, session 3): the five links of the grid on screen, then
  "Reopened 1978 hyperlink", "Birch, 1934 table" and "hyperlink Reopened 1978", `ax:links`
  "Reopened 1978", the next heading and "Built", and `describe` "hyperlink is in the
  VoiceOver cursor". The walk from the top of the book (`ax:links ax:focus in` and
  twenty-four `nextlink`, session 4): the twenty-one links in order, "routes." and
  "hyperlink Built" among them, and the last three again. No transcript of the run has
  "ERROR" in it or VoiceOver's opening phrase a second time, there is no crash report, and
  the run reports `"billable": {}`.
  With `main` merged in, at `b71a6fe`, the first two step lists were heard once more (run
  38456437527) and said the same: "Reopened 1978 hyperlink", "routes." and "hyperlink
  Built", `ax:links` with "Built" first, `describe` "hyperlink is in the VoiceOver
  cursor", the three links after it and "hyperlink upper jump", and in the session without
  the caret step "In text Tables of data" and `line` "Route, Built, Length table". The
  book there has 24,675 characters where it had 23,065, the row is where it was, and after
  the caret step the screen began at character 17188 where it had begun at 17140.
  The logging reader is not in the change (the two trial commits are reverted in
  `8b83d10`). In its first run the reader quit in each session, after the steps that said
  the fault in the first: a link's log line asked the link for its title through the
  method it was logging, without end. The three reports macOS wrote say so, and that run
  failed for it. The second session of that run began on the dialog macOS showed for it,
  the reader quit again at `ax:links` in the third, and neither is evidence of anything
  ([probing what VoiceOver asks the app](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover-mac.md#probing-what-voiceover-asks-the-app)).
  With a caret set after the grid in the section before (`ax:caret=Shown words after the
  grid`, run 38453482423, session 4) the first `nextlink` said "worded jump hyperlink", a
  link above the caret: from a place in the text Find Next Link takes the first link the
  text lists, as an earlier entry here has it.
  Unit tests:
  `testALinkInARowShownBelowEstimatedTextStaysTheTextsLinkWhenTheTextAboveIsLaidOut`, with
  the link in a table's first row and in a later one, and
  `testTheRowsOnScreenKeepTheirCellsWhenTheTextAboveIsLaidOutBehindTheView`
  (`TableCellLinkAccessibilityTests`). Both fail without the change: the first with the
  children "Dogwood" alone, the bounds of VoiceOver's line 888 points below the screen and
  cells on the tall row; the second with the cells of the rows on screen gone.
  Not heard: anyone listening, or any Mac but the runner; another width or text size; a
  link of the text's own, not a cell's, reached the same way, whose element is kept by its
  place in the text and was never seen to leave; VoiceOver's move to a heading below the
  screen from a link, which was not tried here; pages, where a page is laid out whole. On
  iPhone and iPad nothing changes: the hold is the Mac's, and the package was built for
  the simulator and its tests were not run there.
- After that on 2026-10-13 a table cell that shows a picture was heard on a Mac, before
  and after it was given the picture's image to hold: the two tables of data of the
  fixture's last section (`-SampleHref OPS/squares.xhtml`), the second of which was added
  for it at the target `crests`, on GitHub's hosted `xcode-27` runner (image
  `20261006.0244.1`, macOS 27.0.1 `26A434`, Xcode 27.0), in a window 600 points wide at
  17 points, with VoiceOver's link setting at Speak, at a fixed pause of four seconds.
  Nobody listened. Before is `main` at `808ab79` with the table added and nothing of the
  reader changed. For the table under "Sign" and "Sense" that is `a462911` (run
  38449925454, sessions 1, 2 and 4). For the table under "Crest" and "Rank", whose last
  row was added while that run was on its runner, it is the trial builds `787f805` and
  `59018bd` with no launch argument (run 38450656619, session 1, in pages, and run
  38451755191, session 7, in continuous scroll). After is `cdf0101`, which has `main` at
  `888fd7b` merged in
  (run 38456300690, five sessions, and run 38456337909, six).
  [#513](https://github.com/vocaro/EPUBLib/pull/513) and
  [#514](https://github.com/vocaro/EPUBLib/pull/514) merged between the trials and the
  sessions after; the second gives a header cell that is a link a link to hold, in the
  code this changes. All thirty-one sessions of the six runs completed, none has "ERROR"
  in it or VoiceOver's opening phrase a second time, no run has a crash report, and each
  reports `"billable": {}`. The harness was the branch's own.
  The same steps before and after. On the table under "Sign" and "Sense", at the top of
  the section's second page: `ax:next ax:lines ax:tables "ax:caret=Words before the
  signs"`, a focus change to the text, `in`, `line` and three `nextline` to "Blue badge,
  Open table", then `in describe right left nextline previousline actions listdown
  listdown listdown listclose in right out out`; and four `nextline` to "Shut table", then
  `in describe right left actions listdown listdown listclose in right out out`. On the
  table under "Crest" and "Rank" (`"launch=-SampleHref OPS/squares.xhtml#crests" ax:lines
  ax:tables "ax:caret=Words before the crests"`): three `nextline` to "Worn Blue crest
  daily, High table", then `in describe right nextline rowheader columnheader left
  nextline describe right describe in right out actions listdown listdown listdown
  listclose out`. In continuous scroll the same ways in, with `"ax:tables=Words before
  the signs"` or `"ax:tables=Words before the crests"`, and shorter walks of the same
  cells. A phrase is cut at 64 characters, shown by "…", and "￼" is U+FFFC, the
  attachment's character, where VoiceOver was given it to say.

  | Move | Before | After |
  | --- | --- | --- |
  | Into the table at the row of the described picture | "In Blue badge, Open table Sign ￼" | "In Blue badge, Open table Sign Blue badge image" |
  | Control-Option-F3 | "￼ cell is in the VoiceOver cursor" | "Blue badge image image cell is in the VoiceOver cursor" |
  | Along the row and back | "Sense Open", "Sign ￼" | "Sense Open", "Sign Blue badge image" |
  | The hint that follows | "actions available You are currently on a cell, inside of a table…" | "actions available You are currently on a image cell, inside of a…" |
  | Down the column to the picture nobody describes, and back up | "￼", "￼" | "image cell", "Blue badge image" |
  | The Actions menu on the described picture's cell | "Actions menu 2 items", "Inspect Image: Blue badge", "Select Cell Text" | the same |
  | Closing the menu | "￼ cell" | "Blue badge image image cell" |
  | Control-Option-Shift-Down on that cell | "In text Blue badge image" | "In Blue badge image image cell Blue badge image" |
  | Control-Option-Right after it | "Blue badge image", in the cell's text | "Sense Open", the next cell of the row |
  | Control-Option-Shift-Up, twice | "Out of text", "Out of Blue badge, Open table" | "Out of Blue badge, Open table", and nothing |
  | Into the table at the row of the picture nobody describes | "In Shut table Sign ￼" | "In Shut table Sign image cell" |
  | Control-Option-F3 | "￼ cell is in the VoiceOver cursor" | "image cell is in the VoiceOver cursor" |
  | Along the row and back | "Sense Shut", "Sign ￼" | "Sense Shut", "Sign image cell" |
  | Its Actions menu, and closing it | "Actions menu 1 item", "Inspect Image"; "￼ cell" | the same items; "image cell" |
  | Control-Option-Shift-Down, Control-Option-Right, Control-Option-Shift-Up twice | "In text image", "image", "Out of text", "Out of Shut table" | "In image cell image", "Sense Shut", "Out of Shut table", nothing |
  | Into the table at the row of a picture among words | "In Worn Blue crest daily, High table Crest Worn ￼ daily" | "In Worn Blue crest daily, High table Crest Worn ￼ daily, Blue cr…" |
  | Control-Option-F3 | "Worn ￼ daily cell is in the VoiceOver cursor" | "Worn ￼ daily, Blue crest image cell 2 items is in the VoiceOver …" |
  | Along the row, and down the column to the cell beside the header cell that is a picture | "Rank High", "￼ Low" | "Rank High", "Blue shield Low" |
  | Control-Option-R and Control-Option-C there | "￼", "Rank" | "Blue shield", "Rank" |
  | Back along the row to that header cell | "Crest ￼" | "Crest Blue shield image" |
  | Down the column to the cell of decoration alone | "￼", and the hint "You are currently on a cell, inside of a table…" | "empty cell", and "You are currently on a empty cell, inside of a table…" |
  | Control-Option-F3 | "￼ cell is in the VoiceOver cursor" | "empty cell is in the VoiceOver cursor" |
  | Along the row to the cell of two pictures | "Rank ￼   ￼" | "Rank Blue ring image, Blue star image" |
  | Control-Option-F3 | "￼   ￼ cell is in the VoiceOver cursor" | "Blue ring image, Blue star image cell 2 items is in the VoiceOve…" |
  | Control-Option-Shift-Down, Control-Option-Right, Control-Option-Shift-Up there | "In text Blue ring image   Blue star image", "Blue ring image", "Out of text" | "In Blue ring image, Blue star image cell 2 items Blue ring image", "Blue star image", "Out of Blue ring image, Blue star image cell 2 items" |
  | Its Actions menu, and closing it | "Actions menu 3 items", "Inspect Image: Blue ring", "Inspect Image: Blue star", "Select Cell Text"; "￼   ￼ cell" | the same items; "Blue ring image, Blue star image cell 2 items" |
  | The picture cells in `ax:tables` | each an `AXCell` that holds `AXTextArea`, said by "￼", "Worn ￼ daily" or "￼ ￼"; the header of the third row "￼" | `AXImage` for a picture alone, `AXImage,AXImage` for two, `AXTextArea,AXImage` for the picture among words, nothing for decoration; the header of the third row "Blue shield" |

  Each move made in continuous scroll said what it said in pages, before and after.
  Before, with the table of crests far below the screen there, `ax:tables` gave the third
  row's header as "Blue shield": a header cell off screen is given by its words, as
  static text, and it was the cell on screen whose text area said the character. Each
  cell's actions were the same before and after. By line the rows were "Crest, Rank table",
  "Worn Blue crest daily, High table", "Blue shield, Low table" and "Blue ring Blue star
  table" after (run 38456337909, session 3), the labels `ax:tables` gave before, and `in`
  on the last said "In Blue ring Blue star table Crest empty cell".
  Into the words of the cell with a picture among them. Before (run 38449925454, session
  3): `in` "In text Worn  Blue crest image  daily", three `right` "Worn", "Blue crest
  image", "daily", `out` "Out of text". After (run 38456337909, session 1): `in` "In Worn
  ￼ daily, Blue crest image cell 2 items text Worn  Blue c…", `in` again "In text Worn
  Blue crest image  daily", the same three words, `out` "Out of text" and the hint "You
  are currently on a text area, inside of a…", then `right` "Blue crest image" and "You
  are currently on a image, inside of a cell…", where `actions` said "Actions menu 1
  item" and "Inspect Image: Blue crest". The cell's own menu was "Actions menu 2 items",
  "Inspect Image: Blue crest", "Select Cell Text", before and after.
  Inspect Image chosen from the Actions menu, after only. On the cell of the described
  picture (run 38456337909, session 2, `actions listdown "listchoose=Inspect Image: Blue
  badge" ax:wait=2 ax:actions=all`): VoiceOver said "Inspect Image: Blue badge Blue badge
  image image cell", and the window then held Zoom Out, Zoom In, Fit, Close,
  "Magnification" and an image called "Blue badge", so the inspector had opened. On the
  image of the picture among words (session 1): "Inspect Image: Blue crest Blue crest
  image", and the same with an image called "Blue crest".
  What says a picture at its cell was found by trial, each way chosen at launch in one
  build, in pages: `787f805` (run 38450656619), `59018bd` (run 38451755191) and, on the
  shape kept for a picture alone, `c847750` (run 38454390985). For a cell that is one
  picture and nothing else, "Blue badge" under "Sign" and the header cell "Blue shield":

  | The cell | Coming to it, and to the picture nobody describes | Control-Option-F3 | Going in | The cell beside the header cell, and Control-Option-R |
  | --- | --- | --- | --- | --- |
  | Holds its text area, as before | "Sign ￼"; "￼" | "￼ cell is in the VoiceOver cursor" | "In text Blue badge image" | "￼ Low", "￼" |
  | The same, the text area called by the picture's words | the same | the same | "In text image", on the other picture | "￼ Low", "￼" |
  | The same, the cell called by them | "Crest ￼ Blue shield" | not sent | not sent | "￼ Low", "￼" |
  | The same, the words for the text area's value | "Crest ￼" | not sent | not sent | "Blue shield Low", "Blue shield" |
  | The same, the words for the string of a range of it | "Sign ￼"; "￼" | "￼ cell is in the VoiceOver cursor" | "In text" and nothing, on the other picture | "￼ Low", not sent |
  | Holds an image that holds its text area | "Sign ￼"; "￼" | "￼ image cell is in the VoiceOver cursor" | "In Blue badge image text Blue badge image", "Out of Blue badge image" | not sent |
  | Holds an image with the help of an image in text, and no text area | "Sign Blue badge image Double-click or choose Inspect Image to en…"; "image cell" | "Blue badge image Double-click or choose Inspect Image to enlarge…" | "In Blue badge image Double-click or choose Inspect Image to enla…", and the next move went on along the row | "Blue shield Low", "Blue shield" |
  | Holds an image without help, and no text area | "Sign Blue badge image"; "image cell" | "Blue badge image image cell is in the VoiceOver cursor" | "In Blue badge image image cell Blue badge image", and the next move went on along the row | "Blue shield Low", "Blue shield" |

  For the cell that shows a picture among words, "Worn", "Blue crest" and "daily" under
  "Crest":

  | The cell | Coming to it | Control-Option-F3 | Going in |
  | --- | --- | --- | --- |
  | Holds its text area, as before | "Crest Worn ￼ daily" | "Worn ￼ daily cell is in the VoiceOver cursor" | "In text Worn  Blue crest image  daily", then by word "Worn", "Blue crest image", "daily" |
  | The same, the text area called by the cell's words | the same | the same | not sent |
  | The same, the cell called by them | "Crest Worn ￼ daily Worn Blu…" | "Worn ￼ daily Worn Blue crest daily cell is in the VoiceOver curs…" | not sent |
  | The same, the words for the text area's value | "Crest Worn ￼ daily" | "Worn ￼ daily cell is in the VoiceOver cursor" | not sent |
  | The same, the words for the string of a range of it | the same | the same | "In text Worn  Blue crest image  daily", then by word "Worn", "Blue crest image  da", "ily" |
  | Holds its text area and then an image with help | "Crest Worn ￼ daily, Blue cr…" | "Worn ￼ daily, Blue crest image Double-click or choose Inspect Im…" | "In Worn ￼ daily, Blue crest image Double-click or choose Inspect…", and again "In text Worn  Blue crest image  daily" |
  | Holds its text area and then an image without help | "Crest Worn ￼ daily, Blue crest image" | "Worn ￼ daily, Blue crest image cell 2 items is in the VoiceOver …" | "In Worn ￼ daily, Blue crest image cell 2 items text Worn  Blue c…", and again "In text Worn  Blue crest image  daily" |

  So at a cell VoiceOver reads a text area by its characters and nothing else of it: not
  its label, not its value, which it does read where the cell heads a row, and not the
  string it gives for a range, from which it takes the words it moves by inside the cell.
  The image the text gives at a picture's character is said inside the cell and not at
  it. A cell's own label is said after what the cell holds, which says a cell's words
  twice. An image around the text area is called by the text area's characters, where a
  link around one is called by them and "hyperlink". What is said at the cell is an
  image the cell holds itself: its label, VoiceOver's "image", and its help if it has
  one, each time. The reader keeps the image without help, alone in a cell that shows
  nothing else and after the text area in a cell of words. The cell of two pictures said
  "Rank ￼   ￼ Blue ring Blue star" with the cell called by its words, and "Blue ring
  image   Blue star image" as one word with the string of a range.
  VoiceOver did not quit. Three sessions at two seconds a key on `cdf0101` (run
  38456337909, sessions 4 to 6) went through every cell of a table with Control-Option-C
  after each move on and Control-Option-R after each move back: the six cells under
  "Sign" and "Sense" in pages, and the eight under "Crest" and "Rank" in pages and in
  continuous scroll, which said the same as each other at every step. "Sign Blue badge
  image" and "Sign", "Sign image cell" and "Sign", "Crest Worn ￼ daily, Blue crest
  image" and "Crest", "Crest empty cell" and "Crest"; on the way back "Rank Low" and
  "Blue shield", "Crest Blue shield image" and "row 3 of 4", "Sign image cell" and "row
  3 of 3". On a cell of the header row Control-Option-C said the row's words, "Sign,
  Sense" and "Crest, Rank".
  What VoiceOver voices for the attachment's character is still not known. The system's
  speech synthesizer says nothing for it: on a workstation (macOS 27.0 `26A428`, the
  default system voice), `say -o` wrote "Sign ￼" to a file of 0.70 seconds, as long as
  "Sign", "Worn ￼ daily" to one as long as "Worn daily", and the character alone to
  one of 0.01. No sound was played, and VoiceOver was not running. If VoiceOver passes
  the character to that voice as it is, a listener heard "Sign" and no more at a cell
  that was a picture, and "Worn daily" at the cell with a picture among its words.
  The first run was started with the table of crests two rows long, and its two
  sessions on that table (3 and 5) made other moves from the header cell on. The row of
  decoration and of two pictures was added while it ran, so that table's before is from
  the trial builds with no launch argument, whose reader is `main`'s, at the steps of
  the sessions after. Where the first run's sessions made the same moves they said the
  same: "Crest Worn ￼ daily", "Rank High", "￼ Low", "￼" at Control-Option-R and
  "Crest ￼".
  Not heard: anyone listening, or any Mac but the runner; a picture's cell far off the
  screen in continuous scroll, which unit tests hold to the same image; a header cell
  with a picture among its words, one that is a picture nobody describes, and a column
  headed by a picture; a cell whose link is a picture, which holds its link; a cell that
  shows a formula, a rule, a hidden label or a table inside it and no words, which still
  holds a text area whose one character is the attachment's; a picture that stands
  before its cell's words, which is said after them; a cell of pictures continued on the
  next page; Read All through these tables; a larger text size; a spread of two columns;
  a note's popover; Safari on this section; and VoiceOver in another language.
- On 2026-10-13 a table's select action was performed with VoiceOver on the physical iPad
  Air 13-inch (M3) (iPadOS 27.2, 1024 × 1366, upright, 17 points), before and after a
  change to what it does ([#450](https://github.com/vocaro/EPUBLib/issues/450);
  [VoiceOver keeps an item's traits and actions as it found them](https://github.com/vocaro/apple-engineering/blob/main/knowledge/apple/voiceover-ios.md#voiceover-keeps-an-items-traits-and-actions-as-it-found-them)),
  with the sample's selection line under the reader. Nobody listened. The revisions here are the
  branch that reads a table of data by its cells with this change on it, before that
  branch and the `main` of that night were merged in; the last paragraph has the head.
  Before, at `35a8f53`, which has the probe's new steps and nothing of the change. In
  pages, on "Alder" in the tables of data, the rotor offered Next Page, Previous Page and
  Select Cell Text. With that chosen a double tap left VoiceOver's phrase at "Select Cell
  Text", and no other came in four seconds. The reader's line said "Selected: Alder. Used:
  nothing.": the words were selected on the device, and the host was told. The screenshot
  shows VoiceOver's cursor round the cell and the cell's ground white throughout. Nothing
  on screen was named Copy or Use passage, and thirty-six more steps of the rotor went
  round Activate Default, Next Page, Previous Page and Select Cell Text. On the row "First
  cell Second cell" of the section with a hidden heading over a table, the same with
  Select Table Text: Second cell: the phrase stayed, the line said "Selected: Second cell.
  Used: nothing.", and in the screenshot "Second cell" is a little heavier than "First
  cell", where the cell had drawn its ink over the row's, with no tint behind it.
  A first change, at `3e5289d`, painted the selection, posted an announcement and offered
  the three actions. On the iPad the double tap brought "Selected: Alder", the reader's own
  announcement, and the screenshot shows the tint behind "Alder". The rotor went round the
  same four actions as before, through thirty-six steps: VoiceOver keeps an item's actions
  as it found them when its cursor came to the item. The unit tests of that revision
  passed.
  After, at `2738aa9`, which marks the item selected and tells VoiceOver that it changed,
  in place of the announcement. On "Alder" in pages the double tap brought "selected Alder
  Row header Row 2 Column 1" and "Selected: Alder. Used: nothing."; the screenshot shows
  the tint behind "Alder" and nowhere else; the rotor's next two steps were "Copy" and "Use
  passage"; with Use passage chosen a double tap brought "Selected: Alder. Used: Alder.";
  and four steps on stood "Deselect Cell Text", where a double tap brought "Alder Row
  header Row 2 Column 1" and "Selected: nothing. Used: Alder.", with no tint left in the
  screenshot. Selected once more, a touch on "Birch" and then on "Alder" said "selected
  Alder Row header Row 2 Column 1". On the row in pages: "selected First cell Second cell",
  "Selected: Second cell. Used: nothing.", the tint behind "Second cell" alone, "Copy", "Use
  passage", "Selected: Second cell. Used: Second cell.", and "Deselect Table Text: Second
  cell" after "Select Table Text: First cell", which brought "First cell Second cell" and
  "Selected: nothing.". In continuous scroll the row gave the same phrases and lines, with
  the tint in its screenshot. On the cell in continuous scroll the action could not be
  chosen. With VoiceOver's cursor on "Alder", and on "Reopened 1978", thirty turns of the
  rotor went round Rows, Image Recognition, Headings, Containers, Speaking Rate, Words and
  Characters and came to no Actions (`rotor=Actions: MISSING`), at `2738aa9` and at
  `35a8f53` alike, so the change did not bring it; a session whose rotor stood on Actions
  from the session before spelled "Alder" a letter at a time, which is the rotor on
  Characters. The cause is not the cell's and not VoiceOver's
  ([#472](https://github.com/vocaro/EPUBLib/issues/472)): with VoiceOver off, in the
  same place, a finger held on "Alder" selected "Alder", "1901" and "Twelve metres"
  together, the whole row, as the text under a cell's text view does. The cells had no
  text views. A build that reported what the reader finds on screen said why: when the
  book opened at the section the rows were looked for with TextKit's layout 2,660 points
  from where the scroll view stood, no row was on screen, and nothing looked again. After
  one swipe up and one down it found thirty cells, and the held finger selected "Alder"
  alone. So a table the reader goes to itself in continuous scroll has no cell to select
  in or act on until the person scrolls, with VoiceOver or without. The row of the other
  section had its actions; what the layout was there when the book opened was not read.
  With VoiceOver off, a finger held on "Alder" for a second selected it ("Selected: Alder.
  Used: nothing."): the screenshot shows UIKit's tint and its two handles, once, and an
  edit menu of Copy, a symbol, Look Up, Translate and an arrow for more. Nothing on screen
  was named Use passage: by the code a cell's menu has the host's action after the
  system's, where a line's has it first. The iPad simulator (iPad Air 13-inch (M4), iOS
  27.0) gave the same line and the same drawing for that touch at `f76814e`, its menu Copy,
  Look Up, Translate, Search Web and the arrow.
  Copy was not performed on the iPad, where it would have replaced what its owner had
  copied; the unit tests perform it. That VoiceOver speaks an announcement posted from an
  item's action, as "Copied" is, is what the `3e5289d` session heard.
  A step through the rotor took six seconds, most of it XCTest waiting, so a list gone
  round three times took over three minutes. The iPad was unavailable to `devicectl` from
  23:52 until about 01:20 and was shared with three other sessions' runs after that. Each
  session here claimed it in the shared file and read VoiceOver back as off afterward.
  At `8a797bd`, which has that branch as it merged and `main` with it, the cell and the row
  in pages gave the phrases and the lines of `2738aa9` again, action for action. One session
  there opened on a phrase that was not the book's, the sample's or VoiceOver's own,
  something of the device's; its log and result bundle were deleted unread and it was run
  again. No other session recorded such a phrase.
- On 2026-10-13 a table's cells were touched, and acted on with VoiceOver, in continuous
  scroll where the reader had just gone and nobody had scrolled, before and after the reader
  looked for the rows on screen again at the end of each move
  ([#472](https://github.com/vocaro/EPUBLib/issues/472)). The sample opened at the section
  of tables of data (`TEST_RUNNER_VOICEOVER_HREF=OPS/grids.xhtml`,
  `TEST_RUNNER_VOICEOVER_FLOW=scrolled`, `TEST_RUNNER_VOICEOVER_LAUNCH='-SampleSelectionLine YES'`),
  at 17 points. Before is `main` at `229a612`, after is `b818fd7`, which is `main` with the
  change. Nobody listened.
  On the physical iPad Air 13-inch (M3) (iPadOS 27.2, 1024 × 1366, upright), VoiceOver off,
  with steps
  `state,press=Alder,state,screenshot,find=Copy,point=0.03:0.5,press=Express,state,screenshot,point=0.03:0.5,touch=Reopened,wait=1,find=Link target,screenshot`.
  Before: a finger held on "Alder" gave "Selected: Alder	1901	Twelve metres. Used:
  nothing."; the screenshot shows the tint the whole width of the column across that row, a
  handle at each end, and a menu of Use passage, Copy, a symbol and Translate, which is the
  text's own menu and not a cell's. Held on "Express" it gave "Selected: Express	Nine	Noon.
  Used: nothing.". A touch on the link "Reopened 1978" left the section where it was, with
  nothing on screen named "Link target". After: "Selected: Alder. Used: nothing.", the tint
  behind "Alder" alone with its two handles, and a menu of Copy, a symbol, Look Up,
  Translate and an arrow; "Selected: Express. Used: nothing."; and after the touch on the
  link the heading "Link target reached" stood at (152, 209), under the last line of the
  numbered paragraph.
  With VoiceOver, after, with steps
  `touch=Alder,rotor=Actions,choose=Select Cell Text,doubletap=Alder,state,screenshot,choose=Copy,choose=Use passage,doubletap=Alder,state,choose=Deselect Cell Text,doubletap=Alder,state,screenshot`:
  "Alder Row header Row 2 Column 1"; the rotor's turns gave Image Recognition, Containers,
  Speaking Rate, Characters and "Actions Activate"; one step down, "Select Cell Text"; the
  double tap brought "selected Alder Row header Row 2 Column 1" and "Selected: Alder. Used:
  nothing.", and the screenshot shows VoiceOver's cursor round the cell and the tint behind
  "Alder" alone; the next two steps were "Copy" and "Use passage"; with Use passage chosen
  a double tap brought "Selected: Alder. Used: Alder."; two steps on, after "Activate
  Default", stood "Deselect Cell Text", where a double tap brought "Alder Row header Row 2
  Column 1" and "Selected: nothing. Used: Alder.", with no tint left in the screenshot.
  Those are the phrases and lines the same cell gave in pages ([#471](https://github.com/vocaro/EPUBLib/pull/471),
  the entry above). Copy was heard to be offered and was not performed.
  With VoiceOver, before, the fault did not show. In two sessions at `229a612`
  (`touch=Alder,rotor=Actions`, and the same with
  `choose=Select Cell Text,doubletap=Alder,state,screenshot,choose=Copy` after it) the rotor
  came to "Actions Activate" in the same five turns, and in the second "Select Cell Text"
  was offered, the double tap brought "selected Alder Row header Row 2 Column 1" and
  "Selected: Alder. Used: nothing.", and "Copy" followed. The night before, thirty turns on
  that cell in that section had come to no Actions (the entry above), and a touch session at
  the same revision minutes earlier that morning had selected the whole row. What
  gave the cells their text views in the two sessions is not known: any scroll does, and
  so does a layout pass of the reader, which VoiceOver's coming on may bring. So on a
  device the change is shown by touch, and under VoiceOver it is shown that a cell's
  actions are chosen and performed in continuous scroll with the change, not that they
  could not be without it.
  On an iPad Air 13-inch (M4) simulator (iOS 27.0, 1024 × 1366) the touch steps gave the
  same lines and drawings as the iPad, before and after, the menus Use passage, Copy and
  Translate before and Copy, Look Up, Translate, Search Web and an arrow after. There the
  fault showed under VoiceOver as well, with steps
  `touch=Alder,rotor=Actions,choose=Select Cell Text,touch=Express,choose=Select Cell Text`.
  Before: "Alder Row header Row 2 Column 1 Use the rotor to access Headings", thirty turns
  round Headings, Speaking Rate, Words, Rows and Characters (`rotor=Actions: MISSING`), and
  the steps down then went down the column, "Birch Row header Row 3", "Cedar Row header Row
  4"; the same on "Express". After: "Alder Row header Row 2 Column 1 Actions available",
  "Actions Activate" at the fourth turn and "Select Cell Text" one step down, and on
  "Express" "Select Cell Text" again.
  On an iPhone 17 Pro simulator (402 × 874) "Alder" gave the row before and the word after.
  "Express" is cut by the reader's lower edge there. Pressed at that edge it gave its row at
  both revisions, and the view moved under the press; pressed again a second later, whole
  on screen, it gave "Selected: Express." after the change. The link was followed at both
  revisions, the press at the edge having moved the view first: a scroll is what gave the
  cells their text views before the change.
  The unit tests hold the other moves to the same, on both platforms
  ([testing](#testing), the table scrolled-cell tests): without the change a contents
  entry left fifteen to twenty rows of a screen without a text view on any cell, and a step
  of a page twenty-two to forty-one.
  Each device session claimed the iPad in the shared file, and VoiceOver was read back as
  off after each. A phrase the transcript's filter withheld in each VoiceOver session, the
  rotor's first turn, was told from a notification by a comparison that prints true or
  false: it begins "Image Recognition"
  ([physical iPhone and iPad](https://github.com/vocaro/apple-engineering/blob/main/guides/voiceover.md#physical-iphone-and-ipad)).
  No session recorded anything of the device's own.
  The iPhone was not used. Not established: a physical iPhone; landscape; a contents entry,
  a link's target and a step of a page on a device, which the unit tests alone hold; and
  why VoiceOver's sessions at `main` had the cells' text views.
