# Testing

## Local gate

Use Xcode 27, a graphical macOS 27 login, the iOS 27 simulator runtime, XcodeGen and Python 3.
Set `DEVELOPER_DIR` when more than one Xcode is installed. From the repository root:

```sh
bash scripts/check-all.sh
```

The gate verifies all vendored identities, compares documentation snippets with compiled Swift
sources, runs the Mac tests and the full test suite on dedicated iPhone 17 Pro and iPad Air
13-inch (M4) simulators, and builds both sample app targets. Test devices are created by UUID and
deleted on exit; existing devices are never selected or shut down. iOS logs live in
`.build/validation/`. `EPUB_SIM_RUNTIME` selects a different installed runtime by identifier.

For narrower checks:

```sh
swift test --filter PublicationSafetyTests
swift test --filter FoliateIntegrationTests
swift test --filter LayoutRenderingTests
bash scripts/test-ios.sh
```

## Coverage

Parser tests cover EPUB 2/3 structure, navigation, resource access, identity, limits, duplicate ZIP
entries, symlinks, CRC corruption, malformed/deep/wide XML, UTF-16 entities, cancellation after
expansion starts, and exact IDPF/Adobe font deobfuscation vectors. The font tests check the XOR
prefix and the untouched suffix against independently specified keys.

Live WebKit tests mount a reader, check visible text and image geometry, navigate between sections,
exercise styles, locate/select passages, restore positions and close the session. Separate fixtures
exercise encoded filenames and fragments, fixed layout, RTL and vertical writing. The illustrated
fixture has 40 sections and eight incompressible 1024×1024 images; its test enforces an archive size
over 20 MiB and verifies that the first image loads and later sections remain navigable.

These are deterministic regression fixtures, not an EPUB conformance certification, a comprehensive
typographic review, an accessibility audit or a memory budget measurement. WebKit uses separate
processes, so the test runner's memory alone does not describe the reader's total footprint.
The suite runs on OS 27; older platforms are outside the package's deployment targets. Simulator
coverage does not substitute for hardware performance and accessibility testing.

## Adapter contract tests

The internal **EPUBViewingTestSupport** target exercises adapter contracts with
`EPUBEngineContract.verify`. It uses no XCTest or WebKit types, so adapters can call it from
XCTest, Swift Testing or another async test runner. Provide a validated two-section publication,
two distinct encoded resource hrefs, a phrase present in the first section, and a `mount` closure
that places the session in a visible test window and returns a cleanup closure retaining that window.
`FoliateIntegrationTests.testReusableEngineContract` is a complete call-site example.

The verifier checks:

- A pre-cancelled command throws `CancellationError`.
- The mounted session emits `.ready` exactly once.
- Advertised commands can be submitted; unsupported commands return the matching capability error.
- Href navigation changes sections and bookmark restoration returns to the saved section.
- Locations carry the publication identity and a valid engine-tagged bookmark when supported.
- Foreign publication, engine and bookmark format identities are rejected.
- Close is idempotent; closed commands fail and later callbacks are suppressed.

The bundled native SwiftUI test engine runs the same checks without WebKit. Deliberately broken
engines demonstrate that missing/duplicate readiness, ignored cancellation, incompatible restoration
and late callbacks fail the verifier. Adapter-specific tests must additionally check actual rendering,
selection gestures, precise bookmark semantics and resource release. A bounded quiet period after
close detects queued callbacks; it cannot prove that an engine will never emit a much later event.

The contract verifier requires at least two distinct section hrefs when the engine advertises href
navigation. It permits a navigation to the already-current section to be a no-op. `send` acknowledges
submission, so fidelity checks must wait for events or inspect the mounted renderer themselves.
