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
deleted on exit; existing devices are never selected or shut down. iOS logs live in
`.build/validation/`. `EPUB_SIM_RUNTIME` selects a different installed runtime by identifier.

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
`NativeSessionTests.testAMountedReaderIsLightOnADarkMachineUntilTheTestAsksForDark` holds the
harness to that with a dark appearance for its own process.

## Coverage

Parser tests cover EPUB 2/3 structure, navigation, landmarks and page lists, resource access, identity, limits,
duplicate ZIP entries, symlinks, path separators and dot segments beside every scalar that joins
their `Character`, CRC corruption, malformed/deep/wide XML, UTF-16 entities, repeated,
conflicting, absent, remote and differently cased manifest items, references that start at or climb past
the container root or carry a query, padded mimetypes, containers that list another rendition first,
entry names with a colon, contents entries that do not resolve, named character references and
lower-case doctypes in navigation, control characters in navigation,
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
block flow, with their expected native geometry). The illustrated fixture
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
with its issue above it. Three corpus runs are opt-in: `EPUBLIB_W3C_EPUB_TESTS` (the `tests`
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
