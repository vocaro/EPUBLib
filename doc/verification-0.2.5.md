# Version 0.2.5 verification

Environment: macOS 27.0 `26A428` arm64, Xcode 27.0 `27A266a`, iOS 27.0 Simulator `24A434`.
The corpus consists of the library's synthetic fixtures. No inference is used.
`bash scripts/check-all.sh` passes: 104 Mac tests, 102 tests on each of the iPhone 17 Pro
and iPad Air 13-inch (M4) simulators, both sample builds, five documentation snippets and
twelve vendor identities.

In scrolled flow the touch boundary listener now judges a drag by its whole travel from
`touchstart` to the latest position — on every `touchmove` and once more at `touchend`, read
from `changedTouches` — and it is attached to the host document as well as to each section's.
Two separate defects made a real swipe fail to turn, and either alone was enough: WebKit can
deliver one or no `touchmove` events before `touchend` for a quick flick, so a rule that judged
individual moves saw travel below the 32 pt threshold; and a section shorter than the viewport is
sized to its own content, leaving page around its iframe where a touch reaches the host document
and never the section's.

`ScrolledSwipeTurnTests.testAFlickWithNoTouchMoveAdvancesTheSectionFromTheHostPage` drives both
at once on iOS: a two-chapter book whose sections are each shorter than the viewport, so the
renderer reports itself pinned at both edges, then one flick dispatched on `document` with **no
`touchmove` at all**. It asserts the section advances by exactly one. Against 0.2.4's
`bootstrap.js` it fails — "one flick turned 0 sections" — and it passes here. The test is iOS
only: `TouchEvent`/`Touch` are not constructible in macOS WebKit, and the Mac turns pages through
the wheel listener, which is unchanged.

The turn remains cooldown-guarded, so one gesture turns at most one section. Paginated flow still
uses the paginator's own native touch handling and is untouched. Public declarations,
dependencies, capabilities and bookmark formats are unchanged.

Simulator logs and results are under `.build/validation/`. The gate owns and removes its simulators.
