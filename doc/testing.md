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

## Coverage

Parser tests cover EPUB 2/3 structure, navigation, landmarks and page lists, resource access, identity, limits,
duplicate ZIP entries, symlinks, CRC corruption, malformed/deep/wide XML, UTF-16 entities, repeated,
conflicting and absent manifest items, control characters in navigation,
cancellation after expansion starts, and exact IDPF/Adobe font deobfuscation vectors. The font
tests check the XOR prefix and the untouched suffix against independently specified keys.

Viewer component tests cover content-document parsing, the CSS cascade and fonts, attributed-text
building and its text map, images, tables, MathML attachments, CFIs and text search, pagination
geometry and the TextKit 2 views. CFI and search tests replay vectors recorded from foliate-js's own
`epubcfi.js` and `search.js` in WebKit before they were removed, so CFIs the WebKit reader
recorded keep naming the same positions. Live session tests mount a reader in a window, open at
the text start (a `bodymatter` landmark, a guide `text` reference or the first linear section),
navigate between sections, exercise styles and flows, locate/select passages, restore positions
(including a foliate-written CFI under EPUBLib's bookmark identity, refusing the old tag, and a
restore on `.ready` replacing the text start), report the page-list entries on screen in both
flows after page turns, scrolling, navigation to markers, a restore and a resize, and for a
selection, and close the session. Separate fixtures exercise
encoded filenames and fragments, fixed layout, RTL and vertical writing. The illustrated fixture
has 40 sections and eight incompressible 1024×1024 images; its test enforces an archive size over
20 MiB and verifies that later sections remain navigable.

These are deterministic regression fixtures, not an EPUB conformance certification, a comprehensive
typographic review, an accessibility audit or a memory budget measurement.
The suite runs on OS 27; older platforms are outside the package's deployment targets. Simulator
coverage does not substitute for hardware performance and accessibility testing.

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
- Close is idempotent; closed commands fail and later callbacks are suppressed.

A minimal SwiftUI test engine runs the same checks with no renderer at all. Deliberately broken
engines demonstrate that missing/duplicate readiness, ignored cancellation, incompatible restoration
and late callbacks fail the verifier. Adapter-specific tests must additionally check actual rendering,
selection gestures, precise bookmark semantics and resource release. A bounded quiet period after
close detects queued callbacks; it cannot prove that an engine will never emit a much later event.

The contract verifier requires at least two distinct section hrefs when the engine advertises href
navigation. It permits a navigation to the already-current section to be a no-op. `send` acknowledges
submission, so fidelity checks must wait for events or inspect the mounted renderer themselves.
