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
None of this runs on a hosted runner, and nothing starts by itself for a pull request or for
`main`: GitHub's runner is for [Mac VoiceOver sessions](voiceover-testing.md#hosted-mac-sessions)
only ([notes for agents](../AGENTS.md#the-hosted-runner)).

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

A `swift test` that hangs can be made to say where. Written to a file or a pipe, its output
arrives 16 KB at a time, so the log of a run that hangs stops short of the hang, or is empty.
With `NSUnbufferedIO=YES` in its environment `swift test` writes each line as a test makes
it, and the last `Test Case … started.` line with nothing after it names the test. A stack
sample of the process running the tests, the `xctest` that `swift test` starts for a bundle,
has every thread's frames, the test's own with its file and line, and needs no `sudo`:

```sh
NSUnbufferedIO=YES swift test --filter BoxAlignmentCanvasTests > pass.log 2>&1 &
sample "$(pgrep -P $!)" 2 -file hang.txt
```

The second command is for when `pass.log` has stopped growing. `pgrep -P $!` finds the
process this run started and no other session's. On 2026-10-12, with a test made to wait
twenty seconds, a plain run's log was empty ten seconds in, the log of a run with
`NSUnbufferedIO=YES` ended at that test's `started` line, and the sample had the test's frame
on the main thread.

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

Table reading-order tests hold a table on iPhone and iPad to one accessibility element for each
row, between the lines around it and in both flows: text with its cells' words, the actions of
its own cells, a row continued across pages by each page's own words, a row of pictures as an
image without a name, and an empty row or a row of decoration as nothing unless the page holds
nothing else. They also hold every view the reader mounts inside a text
view that lists its lines to being hidden from assistive technology. That VoiceOver reads what
such a view offers before the lines of a page column is known only from
[speech sessions](voiceover-testing.md); no in-process query shows it.

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
[speech sessions](voiceover-testing.md) on a device: the tests passed before the reader told
it anything, and an iPad's rotor still offered Select alone.

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
ask. None of them drives VoiceOver; the [VoiceOver testing process](voiceover-testing.md) has
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
that item does and nothing the last one did. Another holds a data table's cell to being left
and come to as an element of its own. They also hold an element kept from one page to
standing for no line of the next, on pages whose lines have the same characters counted
from each page's first, and to standing for its own line when its page is shown again. That
VoiceOver reads the line for the layout change, draws its cursor there and keeps its rotor,
is known only from [speech sessions](voiceover-testing.md) on a device.

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
recorded with the [VoiceOver testing process](voiceover-testing.md#links).

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
[VoiceOver testing process](voiceover-testing.md).

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
search, one that only highlights, one that lists results, and one that lists them and reports a
step's relocation and a clear's idle state 30 ms late, from a timer of its own. Deliberately broken
engines demonstrate that missing/duplicate readiness, ignored cancellation, incompatible restoration,
late callbacks, results published after completion, steps that do not wrap, stale results that
still navigate, results kept after a clear and a step of a cleared search that still moves the
reader fail the verifier. Adapter-specific tests must additionally check actual rendering,
selection gestures, precise bookmark semantics and resource release.

A bounded quiet period after close detects late callbacks; it cannot prove that an engine will
never emit a much later event. The verifier yields, so that what the engine queued while closing
has started, waits 150 ms, waits 20 ms more and then looks. The second wait is for a callback
sent from a timer of the engine's own. Two sleeps that are both overdue resume in either order,
so a callback sent from a 30 ms sleep can arrive just after the 150 ms has ended. A look at that
moment missed it one time in ten on GitHub's hosted runner, when these tests ran there on
2026-10-12, and a few times in a thousand on a busy Mac. The yield is for a main thread kept
from the engine's queued work until the 150 ms is nearly over: a timer started that late is due
after the look. So one broken engine queues its late callback and another sends it from a 30 ms
sleep, and both are caught. To make the race on a Mac, stop the test process across both sleeps
(`kill -STOP`, then `kill -CONT` 200 ms later, from a helper process): both are overdue when it
continues, and they are delivered together.

The 20 ms is a margin and not a bound. Made that way on this Mac under heavy load on
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
submission, so fidelity checks must wait for events or inspect the mounted renderer themselves.
